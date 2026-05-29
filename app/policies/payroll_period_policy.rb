class PayrollPeriodPolicy < ApplicationPolicy
  def index?             = true  # scope handles isolation
  def show?              = can?(:view_payroll) || visible_to_employee?
  def create?            = can?(:manage_payroll)
  def submit_for_review? = can?(:manage_payroll)
  def regenerate?           = can?(:manage_payroll)
  def approve_all_pending?  = can?(:manage_payroll)
  def finalize?          = can?(:finalize_payroll)
  def mark_paid?         = can?(:manage_payroll)
  def destroy?           = can?(:manage_payroll) && record.draft?

  def complete_branch_review?
    can?(:view_payroll) && same_business?
  end

  class Scope < ApplicationPolicy::Scope
    VISIBLE_TO_EMPLOYEE = %w[finalized paid].freeze

    def resolve
      if user.can?(:view_payroll)
        scope.where(business: user.business)
      else
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
