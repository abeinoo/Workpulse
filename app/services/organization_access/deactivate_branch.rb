module OrganizationAccess
  # Deactivates a branch of the actor's business (BUG-026). Deactivation is how a
  # branch is retired: every historical record keeps its branch reference —
  # nothing is reassigned, nulled or deleted.
  #
  # A business always keeps at least one active branch. The business row is
  # locked first (lock order: business → branch), so two concurrent
  # deactivations of the last two active branches serialize and the second sees
  # the first's committed result. The audit entry is fail-closed (log_audit!):
  # if it cannot be written the deactivation rolls back.
  class DeactivateBranch
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(branch_id, actor:, reason:)
      @branch_id = branch_id
      @actor     = actor
      @reason    = reason.to_s.strip
    end

    def call
      return Result.new(ok: false, error: :reason_required) if @reason.empty?

      ActiveRecord::Base.transaction do
        business = Business.lock.find(@actor.business_id)
        branch   = business.branches.lock.find(@branch_id)
        return Result.new(ok: false, record: branch, error: :not_authorized) unless BranchPolicy.new(@actor, branch).deactivate?
        return Result.new(ok: false, record: branch, error: :already_inactive) unless branch.active?
        return Result.new(ok: false, record: branch, error: :last_active_branch) unless business.branches.active.where.not(id: branch.id).exists?

        branch.update!(active: false)
        log_audit!(actor: @actor, auditable: branch, action: "deactivate",
                   changes: { active: [ true, false ] }, metadata: { reason: @reason, branch_name: branch.name })
        Result.new(ok: true, record: branch)
      end
    rescue ActiveRecord::RecordInvalid, AuditLoggable::AuditWriteFailed => e
      Result.new(ok: false, error: :failed, record: e.try(:record))
    end
  end
end
