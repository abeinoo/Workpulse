module OrganizationAccess
  # Permanently deletes a branch of the actor's business — only one that has
  # never been used (BUG-026). A branch with any history is refused and must be
  # deactivated instead (OrganizationAccess::DeactivateBranch).
  #
  # "Never used" is decided by the data model itself, not by a list kept here:
  # * Branch's history associations are restrict_with_error (attendance,
  #   payroll periods, shift assignments, expenses, …), so destroy returns false;
  # * every other table referencing branches has a foreign key without
  #   ON DELETE (pinned by spec/models/branch_deletion_constraints_spec.rb), so
  #   the database raises ActiveRecord::InvalidForeignKey;
  # * a branch with lifecycle audit entries (e.g. once deactivated) has history.
  # Any refusal rolls the whole transaction back.
  #
  # The last active branch of a business is never deleted. Locks business →
  # branch, like DeactivateBranch. The audit entry is fail-closed (log_audit!)
  # and carries a snapshot of the branch, which no longer exists afterwards.
  class DeleteBranch
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(branch_id, actor:, reason:)
      @branch_id = branch_id
      @actor     = actor
      @reason    = reason.to_s.strip
    end

    def call
      return Result.new(ok: false, error: :reason_required) if @reason.empty?

      outcome = nil
      ActiveRecord::Base.transaction do
        business = Business.lock.find(@actor.business_id)
        branch   = business.branches.lock.find(@branch_id)
        outcome  = refusal_for(business, branch)
        next if outcome

        snapshot = branch.slice(:name, :branch_type, :address, :active)
        unless branch.destroy
          outcome = Result.new(ok: false, record: branch, error: :has_history)
          raise ActiveRecord::Rollback
        end

        log_audit!(actor: @actor, auditable: branch, action: "destroy", metadata: snapshot.merge(reason: @reason))
        outcome = Result.new(ok: true, record: branch)
      end
      outcome
    rescue ActiveRecord::InvalidForeignKey, ActiveRecord::DeleteRestrictionError
      Result.new(ok: false, error: :has_history)
    rescue AuditLoggable::AuditWriteFailed
      Result.new(ok: false, error: :failed)
    end

    private

    def refusal_for(business, branch)
      error =
        if !BranchPolicy.new(@actor, branch).destroy? then :not_authorized
        elsif branch.active? && !business.branches.active.where.not(id: branch.id).exists? then :last_active_branch
        elsif AuditLog.where(auditable_type: "Branch", auditable_id: branch.id).exists? then :has_history
        end
      Result.new(ok: false, record: branch, error: error) if error
    end
  end
end
