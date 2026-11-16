module OrganizationAccess
  # Updates a branch of the actor's business from the Branch form. When the
  # update turns a non-sales branch into a sales branch, its branch warehouse
  # is provisioned in the same transaction through the
  # OrganizationAccess::BranchProvisioning contract — if that fails, the whole
  # update (type change, attributes, POS terminals) rolls back.
  #
  # Nothing else provisions: a sales branch staying a sales branch (a rename
  # or any unrelated edit) and a sales branch leaving sales never touch
  # warehouses — the warehouse of a former sales branch is kept as it is
  # (stock, movements and classification untouched) for manual review.
  # Existing sales branches without a warehouse are left to the separate
  # backfill.
  #
  # Lock order: business, then branch (both FOR NO KEY UPDATE), the same order
  # as the other branch lifecycle services; the branch's type is read only
  # after its lock, so it cannot change between this check and COMMIT.
  # Authorization: BranchPolicy#update?.
  class UpdateBranch
    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    LOCK = CreateBranch::LOCK

    def initialize(branch_id, actor:, attributes:, terminal_rows: nil)
      @branch_id     = branch_id
      @actor         = actor
      @attributes    = attributes
      @terminal_rows = terminal_rows
    end

    def call
      branch  = nil
      outcome = nil
      ActiveRecord::Base.transaction do
        business = Business.lock(LOCK).find(@actor.business_id)
        branch   = business.branches.lock(LOCK).find(@branch_id)
        next outcome = Result.new(ok: false, record: branch, error: :not_authorized) unless BranchPolicy.new(@actor, branch).update?

        was_sales = branch.branch_type_sales?
        next outcome = Result.new(ok: false, record: branch, error: :invalid) unless
          BranchFormAssignment.assign(branch: branch, attributes: @attributes, terminal_rows: @terminal_rows)

        unless branch.save
          outcome = Result.new(ok: false, record: branch, error: :invalid)
          raise ActiveRecord::Rollback
        end

        BranchProvisioning.provision!(branch: branch, actor: @actor) if branch.branch_type_sales? && !was_sales
        outcome = Result.new(ok: true, record: branch)
      end
      outcome
    rescue BranchProvisioning::Failed => e
      branch.errors.add(:base, I18n.t("admin.branches.warehouse_provisioning_failed", reason: e.message))
      Result.new(ok: false, record: branch, error: :warehouse_provisioning_failed)
    end
  end
end
