class PayrollEntryPolicy < ApplicationPolicy
  # Payroll-review authorities — the pipeline participants (who see review-stage
  # periods) plus branch reviewers and payroll recalculators. Holding plain
  # `view_payroll` (e.g. a self-scoped payslip viewer) is not enough.
  OVERTIME_REVIEW_PERMISSIONS = (
    PayrollPeriodPolicy::Scope::PIPELINE_PERMISSIONS + %w[complete_branch_review regenerate_payroll]
  ).freeze

  def index?  = true  # scope handles isolation; employees see only their own finalized/paid entries
  def show?   = can?(:view_payroll) || own_entry?
  # Editing entry-level fields is a payroll-rebuild concern: it requires the
  # same authority as regenerating the period's calculations.
  def update? = can?(:regenerate_payroll)

  # Overriding payable overtime — dedicated permission, only while the period is
  # still editable (draft / under_review / branch_review_completed). Locked
  # (finalized / paid) periods are immutable.
  def override_overtime?
    can?(:manage_payroll_overrides) &&
      record.payroll_period&.business_id == user.business_id &&
      record.payroll_period&.editable?
  end

  # Seeing the overtime-override card (calculated vs approved overtime, the
  # withheld difference, and who overrode it, when, and why) — reviewer data,
  # never shown to a regular employee viewing their own payslip. The payable
  # overtime itself stays visible in the salary breakdown.
  def view_overtime_override?
    overtime_reviewer? && record.payroll_period&.business_id == user.business_id
  end

  # Clearing the "Needs Review" flag — the same reviewer persona that
  # completes Branch Review. Not an approval; just an acknowledgement.
  def mark_reviewed?
    can?(:complete_branch_review) &&
      record.payroll_period&.business_id == user.business_id &&
      record.payroll_period&.editable?
  end

  # The branches whose payroll a user may see in aggregate (payroll cost per
  # branch, branch breakdowns): none without view_payroll; with it, the
  # branches of the view_payroll data scope, resolved by BranchScope from the
  # configured scope (self → none, branch → managed, area → area-managed,
  # business → all) or, none configured, its default (managed + area-managed;
  # every branch for the owner). The branch form of the same view_payroll scope
  # Scope applies to entries — the single definition Payroll analytics and the
  # Finance & Sales reports (which read it) use (decisions of 2026-10-19).
  def self.visible_branch_ids(user)
    return Set.new.freeze unless user.can?(:view_payroll)

    BranchScope.new(user).for_scope(user.scope_for(:view_payroll)).to_set.freeze
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      business_scoped = scope.joins(:payroll_period)
                             .where(payroll_periods: { business_id: user.business_id })

      if user.can?(:view_payroll)
        if (configured = user.scope_for(:view_payroll))
          filter_by_data_scope(business_scoped, configured)
        else
          business_scoped.where(user_id: EmployeeScope.new(user).relation.select(:id))
        end
      else
        scope.joins(:payroll_period)
             .where(user_id: user.id)
             .where(payroll_periods: { status: %w[finalized paid] })
      end
    end
  end

  private

  def own_entry?
    record.user_id == user.id
  end

  def overtime_reviewer?
    OVERTIME_REVIEW_PERMISSIONS.any? { |permission| can?(permission) }
  end
end
