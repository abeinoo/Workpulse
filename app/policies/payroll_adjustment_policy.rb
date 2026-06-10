class PayrollAdjustmentPolicy < ApplicationPolicy
  def index?
    # Any authenticated user in the business may open the Adjustments collection.
    # What they actually see is decided by Scope, not here: employees get only their
    # own approved adjustments; managers/reviewers get their full reviewable scope.
    # `record` is a class for collection-level authorize (e.g. the API index).
    record.is_a?(Class) || same_business?
  end

  def show?
    return false unless same_business?

    # Reviewers (payroll view/manage) and creators see the adjustment in any status —
    # reviewers need pending items to act on, creators see what they authored.
    return true if can?(:view_payroll) || can?(:manage_adjustments)
    return true if record.created_by_id == user.id

    # A plain employee may view an adjustment about themselves only once it has been
    # approved — pending/rejected adjustments are not yet visible to the subject.
    record.user_id == user.id && record.approved?
  end

  def new?
    same_business? && can?(:manage_adjustments)
  end

  def create?
    return false if period_locked?
    same_business? && can?(:manage_adjustments) && record.user.present?
  end

  def approve? = can_review?
  def reject?  = can_review?

  # Bulk approve/reject gate the COLLECTION action: the user must hold
  # approve_adjustments at all. Per-record eligibility (creator ≠ approver, pending
  # only) is still enforced row-by-row by Adjustments::BulkReview, so employees —
  # who lack approve_adjustments — never get the actions, in the UI or via POST.
  def bulk_approve? = same_business? && can?(:approve_adjustments)
  def bulk_reject?  = same_business? && can?(:approve_adjustments)

  # Adjustment Analytics & Reports (the aggregate summary/insights surfaces) are
  # restricted to Business-scope users — owners and admins whose adjustments/payroll
  # authority spans the whole business. Branch- and area-scope managers and plain
  # employees are denied, so both the navigation entry and direct access are hidden.
  def analytics? = same_business? && business_scope_user?
  def reports?   = analytics?

  def destroy?
    return false if period_locked?
    return false unless record.pending_review?
    return false unless same_business?

    can?(:manage_adjustments)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      business_scoped = scope.where(business: user.business)

      if user.can?(:view_payroll) || user.can?(:manage_adjustments)
        # Reviewers/managers see their reviewable employee set (any status, so they
        # can act on pending items), plus anything they created or are the subject of.
        own = "payroll_adjustments.created_by_id = :me OR payroll_adjustments.user_id = :me"
        reviewable_ids =
          if (configured = user.scope_for(:view_payroll))
            EmployeeScope.new(user).for_scope(configured).select(:id)
          else
            EmployeeScope.new(user).relation.select(:id)
          end
        business_scoped.where(
          "payroll_adjustments.user_id IN (:ids) OR #{own}",
          ids: reviewable_ids, me: user.id
        )
      else
        # A plain employee sees ONLY their own adjustments, and only once approved —
        # pending/rejected adjustments about them are not yet visible to the subject.
        business_scoped.where(
          "payroll_adjustments.user_id = :me AND payroll_adjustments.review_status = 'approved'",
          me: user.id
        )
      end
    end
  end

  private

  # A "Business-scope" adjustments user: the owner (always business-wide), or a
  # user whose manage_adjustments / view_payroll authority is explicitly scoped to
  # the whole business. A nil (unset) or narrower (branch/area/self) scope does not
  # qualify, so branch and area managers are excluded.
  def business_scope_user?
    return true if user.owner?

    %i[manage_adjustments view_payroll].any? do |permission|
      user.can?(permission) && user.scope_for(permission) == "business"
    end
  end

  def period_locked?
    period = record.respond_to?(:payroll_period) ? record.payroll_period : nil
    period&.locked?
  end

  def can_review?
    return false unless same_business?

    # The single approval rule for the entire payroll system.
    Payroll::AdjustmentApproval.permitted?(reviewer: user, creator: record.created_by_id)
  end
end
