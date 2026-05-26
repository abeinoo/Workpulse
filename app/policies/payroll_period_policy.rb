class PayrollPeriodPolicy < ApplicationPolicy
  def index?             = true  # scope handles isolation
  def show?              = can?(:view_payroll) || managing? || visible_to_employee?
  def create?            = can?(:manage_payroll) || owner?
  def submit_for_review? = can?(:manage_payroll) || owner?
  def regenerate?           = can?(:manage_payroll) || owner?
  def approve_all_pending?  = can?(:manage_payroll) || owner?
  def finalize?          = can?(:finalize_payroll) || owner?
  def mark_paid?         = owner?
  def destroy?           = owner? && record.draft?

  def complete_branch_review?
    owner? || (manages_branch? && same_business?)
  end

  class Scope < ApplicationPolicy::Scope
    VISIBLE_TO_EMPLOYEE = %w[finalized paid].freeze

    def resolve
      if user.owner? || user.can?(:view_payroll) || user.manages_area? || user.manages_branch?
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

  def managing?
    return false unless same_business?
    can?(:view_payroll) || owner? || manages_area? || manages_branch?
  end

  def visible_to_employee?
    same_business? && (record.finalized? || record.paid?) &&
      record.payroll_entries.exists?(user_id: user.id)
  end
end
