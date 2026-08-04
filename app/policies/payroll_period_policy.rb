class PayrollPeriodPolicy < ApplicationPolicy
  def index?  = true  # scope handles isolation
  def show?   = can?(:view_payroll) || visible_to_employee?

  # ── Lifecycle actions — each gated by its own granular permission ──────────
  def create?               = can?(:create_payroll)
  def submit_for_review?    = can?(:submit_payroll_review)
  def approve_all_pending?  = can?(:approve_payroll_items)
  def adjust_overtime?      = can?(:manage_payroll_overrides) && record.editable?
  def waive_deductions?     = can?(:manage_payroll_deduction_waivers) && record.editable?
  def finalize?             = can?(:finalize_payroll)
  def mark_paid?            = can?(:pay_payroll)
  def destroy?              = can?(:delete_payroll) && record.draft?

  # Regenerate is only permitted while the period is editable. Finalized or
  # paid periods must be reopened before they can be regenerated.
  def regenerate? = can?(:regenerate_payroll) && record.draft?

  # Reopen — finalized → branch_review_completed, paid → finalized.
  # Reopening a paid period additionally requires `pay_payroll` because it
  # rolls back a financial-disbursement event.
  def reopen?
    return false unless can?(:reopen_payroll)

    if record.paid?
      can?(:pay_payroll)
    else
      record.finalized?
    end
  end

  def complete_branch_review?
    can?(:complete_branch_review) && same_business?
  end

  # Bulk-clearing the "Needs Review" flag — same reviewer persona as Branch
  # Review, available for as long as the period stays editable.
  def mark_all_reviewed?
    can?(:complete_branch_review) && same_business? && record.editable?
  end

  # Branch managers may request changes from accounting during the review cycle.
  def request_changes?
    can?(:complete_branch_review) && same_business? && record.under_review?
  end

  # Accounting can resubmit to branch managers after addressing requested changes.
  def resubmit_for_review?
    can?(:submit_payroll_review) && same_business? && record.under_review?
  end

  # Viewing the payroll audit log is gated separately from viewing payroll.
  def view_audit_log? = can?(:view_payroll_audit_log)

  # Bank-transfer CSV export — any payroll viewer may download the payment file,
  # but only once the period is finalised/paid (an approved, locked period).
  def export_payroll_bank_csv? = can?(:view_payroll) && record.locked?

  class Scope < ApplicationPolicy::Scope
    VISIBLE_TO_EMPLOYEE = %w[finalized paid].freeze

    # Permissions that indicate active participation in the payroll review pipeline.
    # Holders see under_review and branch_review_completed periods in addition to
    # finalized/paid because they are directly involved in processing payroll.
    PIPELINE_PERMISSIONS = %w[
      submit_payroll_review
      approve_payroll_items
      manage_payroll_overrides
      manage_payroll_deduction_waivers
      finalize_payroll
      pay_payroll
    ].freeze

    # Payroll period visibility is determined by three factors in combination:
    #
    #   1. Payroll permissions  — view_payroll is the gate; workflow-action permissions
    #                             (submit, finalize, etc.) determine pipeline access.
    #   2. Workflow stage       — a period's status determines who can see it. Holding
    #                             view_payroll does not grant access to every stage.
    #   3. Configured data scope — for finalized/paid periods, the user's configured
    #                              scope for view_payroll limits which entries (and
    #                              therefore which periods) are visible.
    #
    # Authorization is intentionally permission-driven, not role-driven. No role
    # names are referenced here. Any custom role granted the right permission
    # automatically receives the corresponding visibility without code changes.
    def resolve
      base = scope.where(business: user.business)

      # Owners and holders of explicit draft access see every status including draft.
      return base if user.owner? || user.can?(:view_draft_payroll)

      # Without view_payroll, only the user's own finalized/paid entries are visible.
      return employee_self_scope(base) unless user.can?(:view_payroll)

      # view_payroll holders: the workflow stage gates which periods are visible.
      # Build the visible set as a union across the user's workflow roles.
      visible = scope.none

      # Finalized and paid periods are always visible to view_payroll holders,
      # filtered by their configured data scope via PayrollEntry (periods have no
      # direct branch/user column; entries are the join point).
      visible = visible.or(scoped_finalized_periods(base))

      # Payroll pipeline participants (submitters, approvers, finalizers) see the
      # full active review pipeline — under_review and branch_review_completed —
      # across the whole business, because their actions are period-wide.
      if PIPELINE_PERMISSIONS.any? { |p| user.can?(p) }
        visible = visible.or(base.where(status: %w[under_review branch_review_completed]))
      end

      # Branch reviewers see review-stage periods only for branches they are
      # authorized to review — not the entire business.
      if user.can?(:complete_branch_review)
        ids = branch_review_ids
        if ids == :all
          visible = visible.or(base.where(status: %w[under_review branch_review_completed]))
        elsif ids.any?
          period_ids = PayrollPeriodBranchReview.where(branch_id: ids).select(:payroll_period_id)
          visible = visible.or(
            base.where(status: %w[under_review branch_review_completed], id: period_ids)
          )
        end
      end

      visible
    end

    private

    # Finalized/paid periods scoped to the employees this user can see under
    # their configured view_payroll scope. Uses PayrollEntry as the join point.
    def scoped_finalized_periods(base)
      periods = base.where(status: VISIBLE_TO_EMPLOYEE)
      scope_type = user.scope_for(:view_payroll)

      case scope_type
      when "business"
        periods
      when nil
        # No explicit scope — use the hierarchy-based employee relation
        # (employees in branches the user manages as branch_manager / area_manager).
        periods.where(id: entry_period_ids(EmployeeScope.new(user).relation))
      else
        periods.where(id: entry_period_ids(EmployeeScope.new(user).for_scope(scope_type)))
      end
    end

    # Payroll period IDs that contain entries for the given employee relation,
    # always including a period that contains the current user's own entry.
    def entry_period_ids(employee_relation)
      PayrollEntry.where(user_id: employee_relation.select(:id))
                  .or(PayrollEntry.where(user_id: user.id))
                  .select(:payroll_period_id)
    end

    # Branches this user is authorized to complete payroll reviews for.
    # Returns :all for business-wide scope, or an array of branch IDs.
    # Mirrors PayrollPeriodsController#reviewable_branch_ids_for.
    def branch_review_ids
      return :all if user.scope_for(:complete_branch_review) == "business"

      (user.managed_branch_ids + user.area_managed_branch_ids).uniq
    end

    def employee_self_scope(base)
      base.where(status: VISIBLE_TO_EMPLOYEE)
          .joins(:payroll_entries)
          .where(payroll_entries: { user_id: user.id })
    end
  end

  private

  def visible_to_employee?
    same_business? && (record.finalized? || record.paid?) &&
      record.payroll_entries.exists?(user_id: user.id)
  end
end
