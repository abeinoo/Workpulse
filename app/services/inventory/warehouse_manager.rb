module Inventory
  # The single entry point for a warehouse's own lifecycle: create a central
  # warehouse, provision a sales branch's branch warehouse, update its
  # descriptive attributes, and delete a genuinely empty one. Every operation
  # is authorized (WarehousePolicy; provisioning by the branch lifecycle's
  # BranchPolicy — records are loaded inside the actor's business), runs in
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
  #   manager.provision_branch_warehouse(branch: branch)  # branch lifecycle / backfill only
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
    PROVISIONING_SOURCES = %w[branch_provisioning branch_backfill].freeze
    # The only kind #create accepts; "branch" is provision_branch_warehouse's alone.
    CREATABLE_KINDS = %w[central].freeze
    KEEP = Object.new.freeze
    private_constant :KEEP

    def initialize(actor:)
      @actor = actor
    end

    # Creates a CENTRAL warehouse — the manual creation path (the Warehouses
    # page always passes kind "central"). Branch warehouses are never created
    # here: kind "branch" or any branch_id is refused before anything is
    # written. They come only from provision_branch_warehouse (the branch
    # lifecycle and the backfill), which fixes their kind, branch and name.
    #
    # A savepoint (requires_new) so a refusal inside a caller's transaction
    # rolls back only this warehouse and its audit entry — never leaves the
    # caller's transaction aborted. No business or branch lock is taken: a
    # central warehouse belongs to no branch (the name lock still applies).
    def create(kind:, name:, description: nil, status: "active", branch_id: nil)
      return failure(:not_authorized) unless WarehousePolicy.new(@actor, Warehouse).create?
      return failure(:branch_warehouse_requires_provisioning) if kind.to_s == "branch" || branch_id.present?
      return failure(:kind_required)  unless CREATABLE_KINDS.include?(kind.to_s)
      return failure(:status_invalid) unless Warehouse::STATUSES.include?(status.to_s)

      warehouse = Warehouse.new(business_id: @actor.business_id, kind: kind.to_s, name: name,
                                description: description, status: status.to_s)
      Warehouse.transaction(requires_new: true) { persist_new!(warehouse) }
      Result.new(ok: true, warehouse: warehouse)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, AuditLoggable::AuditWriteFailed => e
      creation_failure(e, warehouse)
    end

    # The branch warehouse of a sales branch, created by branch provisioning —
    # reachable only through Inventory::BranchWarehouseProvisioning, the
    # Inventory implementation of OrganizationAccess::BranchProvisioning (pinned
    # by spec/architecture/organization_access_outbound_boundary_spec.rb).
    #
    # Not a general creation path: kind is always "branch", the name always
    # "<Branch Name> – المخزن", the branch must be a sales branch of the actor's
    # own business, and it only runs inside the caller's transaction. The
    # branch lifecycle authorized the change (BranchPolicy, manage_branches), so
    # WarehousePolicy is not asked; the audit entry names that actor and source
    # "branch_provisioning".
    #
    # Lock precondition: the caller holds business -> branch row locks for the
    # rest of its transaction (OrganizationAccess::CreateBranch / UpdateBranch —
    # the only callers, pinned by
    # spec/architecture/organization_access_outbound_boundary_spec.rb). An open
    # transaction alone proves nothing about those locks, so they are taken
    # here again, in the same order and mode: a no-op when the caller holds
    # them (a transaction re-acquiring its own row lock does not wait), and the
    # guarantee itself if a caller ever did not. The branch type is then re-read
    # under the lock, from the database, never from the in-memory record.
    #
    # Idempotent: an existing branch warehouse of this branch is returned as
    # it is (no write, no audit entry). Anything else fails clearly.
    #
    # source — the audit entry's source, one of PROVISIONING_SOURCES:
    # "branch_provisioning" (the branch lifecycle, the default) or
    # "branch_backfill" (Inventory::BranchWarehouseBackfill, existing branches).
    def provision_branch_warehouse(branch:, source: "branch_provisioning")
      return failure(:invalid_provisioning_source) unless PROVISIONING_SOURCES.include?(source)
      return failure(:provisioning_outside_transaction) unless Warehouse.connection.transaction_open?
      return failure(:branch_not_found) unless branch&.persisted? && branch.business_id == @actor.business_id

      Business.where(id: branch.business_id).lock("FOR NO KEY UPDATE").pick(:id)
      locked_type = Branch.where(id: branch.id, business_id: branch.business_id).lock("FOR NO KEY UPDATE").pick(:branch_type)
      return failure(:branch_not_found) if locked_type.nil?
      return failure(:branch_not_sales) unless locked_type == "sales"

      existing = Warehouse.find_by(branch_id: branch.id)
      if existing
        return Result.new(ok: true, warehouse: existing) if existing.kind_branch? && existing.business_id == branch.business_id

        return failure(:branch_warehouse_inconsistent, warehouse: existing)
      end

      warehouse = Warehouse.new(business_id: branch.business_id, kind: "branch", branch: branch,
                                name: self.class.branch_warehouse_name(branch), status: "active")
      Warehouse.transaction(requires_new: true) do
        persist_new!(warehouse, source: source)
      end
      Result.new(ok: true, warehouse: warehouse)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, AuditLoggable::AuditWriteFailed => e
      creation_failure(e, warehouse)
    end

    # The approved branch warehouse name: "<Branch Name> – المخزن".
    def self.branch_warehouse_name(branch) = "#{branch.name} – المخزن"

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

    def persist_new!(warehouse, source: nil)
      warehouse.save!
      metadata = identity(warehouse)
      metadata[:source] = source if source
      log_audit!(actor: @actor, auditable: warehouse, action: "create",
                 changes: { name: [ nil, warehouse.name ], kind: [ nil, warehouse.kind ],
                            branch_id: [ nil, warehouse.branch_id ], status: [ nil, warehouse.status ] },
                 metadata: metadata)
    end

    def creation_failure(error, warehouse)
      case error
      when ActiveRecord::RecordNotUnique
        # Lost a race for the branch: the unique index decided (PR 1).
        failure(:branch_already_has_warehouse, warehouse: warehouse)
      when AuditLoggable::AuditWriteFailed
        failure(:audit_failed, warehouse: warehouse)
      else
        record = error.record
        if record.errors.of_kind?(:branch_id, :taken)
          failure(:branch_already_has_warehouse, warehouse: record)
        elsif record.errors.of_kind?(:name, :taken)
          Result.new(ok: false, warehouse: record, code: :name_taken,
                     error: I18n.t("inventory.warehouses.errors.name_taken", name: record.name))
        else
          invalid(record)
        end
      end
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
