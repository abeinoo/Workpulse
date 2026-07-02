class PayrollPeriodPolicy < ApplicationPolicy
  def index?  = true  # scope handles isolation
  def show?   = can?(:view_payroll) || visible_to_employee?

  # ── Lifecycle actions — each gated by its own granular permission ──────────
  def create?               = can?(:create_payroll)
  def submit_for_review?    = can?(:submit_payroll_review)
  def approve_all_pending?  = can?(:approve_payroll_items)
  def adjust_overtime?      = can?(:manage_payroll_overrides) && record.reviewable?
  def waive_deductions?     = can?(:manage_payroll_deduction_waivers) && record.reviewable?
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
    VISIBLE_TO_EMPLOYEE     = %w[finalized paid].freeze
    VISIBLE_AFTER_SUBMITTED = %w[under_review branch_review_completed finalized paid].freeze

    def resolve
      if user.owner? || user.can?(:view_draft_payroll)
        # Owners and anyone explicitly granted view_draft_payroll see all statuses including draft.
        scope.where(business: user.business)
      elsif user.can?(:view_payroll)
        # Branch managers and other payroll viewers see from under_review onward.
        scope.where(business: user.business)
             .where(status: VISIBLE_AFTER_SUBMITTED)
      else
        # Employees — only their own finalized/paid entries.
        scope.where(business: user.business)
             .where(status: VISIBLE_TO_EMPLOYEE)
             .joins(:payroll_entries)
             .where(payroll_entries: { user_id: user.id })
      end
    end
  end

  private

  def visible_to_employee?
    same_business? && (record.finalized? || record.paid?) &&
      record.payroll_entries.exists?(user_id: user.id)
  end
end
