module Inventory
  # Sets (or changes / deactivates) a branch's primary supplying warehouse —
  # the explicit WarehouseBranchSupply link. Configuration for branch-level
  # reporting only: it never touches stock or the movement ledger.
  #
  # Upsert by branch (one row per branch). The previous warehouse / status is
  # kept in the audit log, so every change is traceable.
  class WarehouseSupplyAssigner
    include AuditLoggable

    Result = Struct.new(:ok, :supply, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(branch_id:, warehouse_id:, active:, actor:)
      @branch_id    = branch_id
      @warehouse_id = warehouse_id
      @active       = ActiveModel::Type::Boolean.new.cast(active) != false
      @actor        = actor
    end

    def call
      branch    = Branch.where(business_id: @actor.business_id).find(@branch_id)
      warehouse = Warehouse.where(business_id: @actor.business_id).find(@warehouse_id)
      supply    = nil

      WarehouseBranchSupply.transaction do
        supply = WarehouseBranchSupply.lock.find_or_initialize_by(branch_id: branch.id)
        before = supply.persisted? ? { warehouse_id: supply.warehouse_id, active: supply.active } : {}
        supply.assign_attributes(business_id: @actor.business_id, warehouse: warehouse, active: @active,
                                 updated_by: @actor)
        supply.created_by ||= @actor
        supply.save!

        log_audit(actor: @actor, auditable: supply, action: before.empty? ? "create" : "update",
                  changes: { warehouse_id: [ before[:warehouse_id], warehouse.id ], active: [ before[:active], @active ] },
                  metadata: { branch_id: branch.id, branch: branch.name, warehouse: warehouse.name })
      end

      Result.new(ok: true, supply: supply)
    rescue ActiveRecord::RecordNotFound
      Result.new(ok: false, error: I18n.t("inventory.warehouse_supplies.errors.not_found"))
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, supply: e.record, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
