module Inventory
  # The single entry point for a warehouse's own lifecycle: create (central or
  # branch), update its descriptive attributes, and delete a genuinely empty
  # one. Every operation is authorized with the existing WarehousePolicy
  # (records are loaded through its scope inside the actor's business), runs in
  # one transaction and writes a fail-closed audit entry (log_audit!) in that
  # same transaction — so an entry can never claim a change that rolled back,
  # and a change whose audit cannot be written does not happen.
  #
  # Structural identity (business, kind, owning branch) is never changed here:
  # update only accepts name / description / status, and the model refuses any
  # other structural change (Warehouse#structural_identity_unchanged).
  #
  #   manager = Inventory::WarehouseManager.new(actor: user)
  #   manager.create(kind: "central", name: "Main")
  #   manager.create(kind: "branch", name: "Shubra – المخزن", branch_id: 3)
  #   manager.update(warehouse_id: 7, name: "Renamed")
  #   manager.destroy(warehouse_id: 7, reason: "Created by mistake")
  class WarehouseManager
    include AuditLoggable

    Result = Struct.new(:ok, :warehouse, :error, :code, :blockers, keyword_init: true) do
      def ok? = ok
    end

    # Everything that keeps a warehouse: one entry per foreign key that
    # references warehouses (all Inventory & Purchasing tables). Coverage is
    # pinned by spec — a new reference to warehouses fails it until listed.
    # stock_issues also covers reservations (an approved issue reserves stock).
    REFERENCES = {
      inventory_movements:        ->(id) { InventoryMovement.where(warehouse_id: id) },
      stock_issues:               ->(id) { StockIssue.where(warehouse_id: id) },
      goods_receipts:             ->(id) { GoodsReceipt.where(warehouse_id: id) },
      stock_adjustments:          ->(id) { StockAdjustment.where(warehouse_id: id) },
      stock_counts:               ->(id) { StockCount.where(warehouse_id: id) },
      stock_transfers:            ->(id) { StockTransfer.where(source_warehouse_id: id).or(StockTransfer.where(destination_warehouse_id: id)) },
      stock_issue_import_batches: ->(id) { StockIssueImportBatch.where(warehouse_id: id) },
      purchase_requests:          ->(id) { PurchaseRequest.where(warehouse_id: id) },
      purchase_request_items:     ->(id) { PurchaseRequestItem.where(source_warehouse_id: id) },
      product_warehouse_settings: ->(id) { ProductWarehouseSetting.where(warehouse_id: id) },
      # Access configuration still blocks: removing a user's only assignment
      # would widen them to every warehouse (User#inventory_warehouse_ids).
      warehouse_assignments:      ->(id) { WarehouseAssignment.where(warehouse_id: id) },
      warehouse_branch_supplies:  ->(id) { WarehouseBranchSupply.where(warehouse_id: id) }
    }.freeze

    UPDATABLE = %i[name description status].freeze
    KEEP = Object.new.freeze
    private_constant :KEEP

    def initialize(actor:)
      @actor = actor
    end

    def create(kind:, name:, branch_id: nil, description: nil, status: "active")
      return failure(:not_authorized) unless WarehousePolicy.new(@actor, Warehouse).create?
      return failure(:kind_required)  unless Warehouse::KINDS.include?(kind.to_s)
      return failure(:status_invalid) unless Warehouse::STATUSES.include?(status.to_s)

      branch = nil
      if branch_id.present?
        branch = Branch.find_by(id: branch_id, business_id: @actor.business_id)
        return failure(:branch_not_found) unless branch
      end

      warehouse = Warehouse.new(business_id: @actor.business_id, kind: kind.to_s, branch: branch,
                                name: name, description: description, status: status.to_s)
      Warehouse.transaction do
        warehouse.save!
        log_audit!(actor: @actor, auditable: warehouse, action: "create",
                   changes: { name: [ nil, warehouse.name ], kind: [ nil, warehouse.kind ],
                              branch_id: [ nil, warehouse.branch_id ], status: [ nil, warehouse.status ] },
                   metadata: identity(warehouse))
      end
      Result.new(ok: true, warehouse: warehouse)
    rescue ActiveRecord::RecordInvalid => e
      return failure(:branch_already_has_warehouse, warehouse: e.record) if e.record.errors.of_kind?(:branch_id, :taken)

      invalid(e.record)
    rescue ActiveRecord::RecordNotUnique
      # Lost a race for the branch: the unique index decided (PR 1).
      failure(:branch_already_has_warehouse, warehouse: warehouse)
    rescue AuditLoggable::AuditWriteFailed
      failure(:audit_failed, warehouse: warehouse)
    end

    # Only the given attributes change; structural attributes are not accepted.
    def update(warehouse_id:, name: KEEP, description: KEEP, status: KEEP)
      attributes = { name: name, description: description, status: status }.reject { |_, v| v.equal?(KEEP) }
      return failure(:status_invalid) if attributes.key?(:status) && !Warehouse::STATUSES.include?(attributes[:status].to_s)

      warehouse = nil
      Warehouse.transaction do
        warehouse = scoped.lock.find_by(id: warehouse_id)
        next failure(:not_found) unless warehouse
        next failure(:not_authorized, warehouse: warehouse) unless WarehousePolicy.new(@actor, warehouse).update?

        warehouse.assign_attributes(attributes)
        changes = warehouse.changes_to_save.slice(*UPDATABLE.map(&:to_s))
        next Result.new(ok: true, warehouse: warehouse) if changes.empty?

        warehouse.save!
        log_audit!(actor: @actor, auditable: warehouse, action: "update", changes: changes,
                   metadata: identity(warehouse))
        Result.new(ok: true, warehouse: warehouse)
      end
    rescue ActiveRecord::RecordInvalid => e
      invalid(e.record)
    rescue AuditLoggable::AuditWriteFailed
      failure(:audit_failed, warehouse: warehouse)
    end

    # Deletes a warehouse only when nothing references it. The row is locked
    # (FOR UPDATE) before the checks: a concurrent write that references the
    # warehouse needs a key-share lock on it, so it either committed before
    # the checks (and is seen) or waits and then fails its foreign key once
    # the row is gone. The foreign keys (no ON DELETE) stay the final guard.
    def destroy(warehouse_id:, reason:)
      reason = reason.to_s.strip
      return failure(:reason_required) if reason.empty?

      warehouse = nil
      Warehouse.transaction do
        warehouse = scoped.lock.find_by(id: warehouse_id)
        next failure(:not_found) unless warehouse
        next failure(:not_authorized, warehouse: warehouse) unless WarehousePolicy.new(@actor, warehouse).destroy?

        blockers = blockers_for(warehouse.id)
        next in_use(warehouse, blockers) if blockers.any?

        snapshot = identity(warehouse).merge(name: warehouse.name, description: warehouse.description,
                                             status: warehouse.status, reason: reason)
        warehouse.destroy!
        log_audit!(actor: @actor, auditable: warehouse, action: "destroy", metadata: snapshot)
        Result.new(ok: true, warehouse: warehouse)
      end
    rescue ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotDestroyed
      # The database (or a restrict association) refused: re-read what holds it
      # now that the transaction has rolled back.
      in_use(warehouse, warehouse ? blockers_for(warehouse.id) : [])
    rescue AuditLoggable::AuditWriteFailed
      failure(:audit_failed, warehouse: warehouse)
    end

    # The reasons a warehouse cannot be deleted, as reference keys (stock on
    # hand first, then every referencing table). Empty = deletable.
    def blockers_for(warehouse_id)
      blockers = []
      blockers << :stock_on_hand if stock_on_hand?(warehouse_id)
      blockers + REFERENCES.select { |_, relation| relation.call(warehouse_id).exists? }.keys
    end

    private

    def scoped
      WarehousePolicy::Scope.new(@actor, Warehouse).resolve
    end

    def stock_on_hand?(warehouse_id)
      InventoryMovement.where(warehouse_id: warehouse_id).group(:product_id)
                       .having(Arel.sql("#{StockLevels::SIGNED_SUM} <> 0")).exists?
    end

    def identity(warehouse)
      { business_id: warehouse.business_id, kind: warehouse.kind, branch_id: warehouse.branch_id }
    end

    def in_use(warehouse, blockers)
      blockers = [ :other_records ] if blockers.empty?
      labels   = blockers.map { |key| I18n.t("inventory.warehouses.references.#{key}") }
      Result.new(ok: false, warehouse: warehouse, code: :in_use, blockers: blockers,
                 error: I18n.t("inventory.warehouses.errors.in_use", references: labels.to_sentence))
    end

    def invalid(record)
      Result.new(ok: false, warehouse: record, code: :invalid, error: record.errors.full_messages.to_sentence)
    end

    def failure(code, warehouse: nil)
      Result.new(ok: false, warehouse: warehouse, code: code, error: I18n.t("inventory.warehouses.errors.#{code}"))
    end
  end
end
