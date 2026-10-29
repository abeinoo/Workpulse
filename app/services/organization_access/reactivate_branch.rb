module OrganizationAccess
  # Reactivates a deactivated branch of the actor's business (BUG-026). The
  # branch row is locked so a concurrent deactivation / reactivation decides on
  # committed state; the audit entry is fail-closed (log_audit!).
  class ReactivateBranch
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(branch_id, actor:, reason: nil)
      @branch_id = branch_id
      @actor     = actor
      @reason    = reason.to_s.strip.presence
    end

    def call
      ActiveRecord::Base.transaction do
        branch = Branch.where(business_id: @actor.business_id).lock.find(@branch_id)
        return Result.new(ok: false, record: branch, error: :not_authorized) unless BranchPolicy.new(@actor, branch).reactivate?
        return Result.new(ok: false, record: branch, error: :already_active) if branch.active?

        branch.update!(active: true)
        log_audit!(actor: @actor, auditable: branch, action: "reactivate",
                   changes: { active: [ false, true ] }, metadata: { reason: @reason, branch_name: branch.name }.compact)
        Result.new(ok: true, record: branch)
      end
    rescue ActiveRecord::RecordInvalid, AuditLoggable::AuditWriteFailed => e
      Result.new(ok: false, error: :failed, record: e.try(:record))
    end
  end
end
