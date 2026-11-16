module OrganizationAccess
  # Creates a branch of the actor's business from the Branch form. A sales
  # branch gets its branch warehouse in the same transaction, through the
  # OrganizationAccess::BranchProvisioning contract (Inventory & Purchasing
  # implements it): the branch, its POS terminals, the warehouse and the
  # warehouse's audit entry commit together or not at all — a sales branch is
  # never committed without its warehouse. A non-sales branch (laundry,
  # headquarters, maintenance, warehouse, other) gets none.
  #
  # Lock order: business row first (FOR NO KEY UPDATE — it serializes with the
  # other branch lifecycle services, which lock the business FOR UPDATE, without
  # blocking unrelated inserts that only reference the business), then the
  # provisioning's warehouse write. Authorization: BranchPolicy#create?.
  class CreateBranch
    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    LOCK = "FOR NO KEY UPDATE".freeze

    def initialize(actor:, attributes:, terminal_rows: nil)
      @actor         = actor
      @attributes    = attributes
      @terminal_rows = terminal_rows
    end

    def call
      branch  = nil
      outcome = nil
      ActiveRecord::Base.transaction do
        business = Business.lock(LOCK).find(@actor.business_id)
        branch   = business.branches.build
        next outcome = Result.new(ok: false, record: branch, error: :not_authorized) unless BranchPolicy.new(@actor, branch).create?
        next outcome = Result.new(ok: false, record: branch, error: :invalid) unless
          BranchFormAssignment.assign(branch: branch, attributes: @attributes, terminal_rows: @terminal_rows)

        unless branch.save
          outcome = Result.new(ok: false, record: branch, error: :invalid)
          raise ActiveRecord::Rollback
        end

        BranchProvisioning.provision!(branch: branch, actor: @actor) if branch.branch_type_sales?
        outcome = Result.new(ok: true, record: branch)
      end
      outcome
    rescue BranchProvisioning::Failed => e
      branch.errors.add(:base, I18n.t("admin.branches.warehouse_provisioning_failed", reason: e.message))
      Result.new(ok: false, record: branch, error: :warehouse_provisioning_failed)
    end
  end
end
