class PayrollPeriodPolicy < ApplicationPolicy
  def index?             = super_admin? || area_manager? || branch_manager? || accountant? || employee?
  def show?              = managing? || visible_to_employee?
  def create?            = super_admin? || accountant?
  def submit_for_review? = super_admin? || accountant?
  def regenerate?        = super_admin?
  def finalize?          = super_admin?
  def mark_paid?         = super_admin?
  def destroy?           = super_admin? && record.draft?

  # Branch managers complete the review for their own branch(es).
  def complete_branch_review? = branch_manager? && same_business?

  class Scope < ApplicationPolicy::Scope
    VISIBLE_TO_EMPLOYEE = %w[finalized paid].freeze

    def resolve
      if user.super_admin? || user.accountant? || user.area_manager? || user.branch_manager?
        scope.where(business: user.business)
      elsif user.employee?
        scope.where(business: user.business)
             .where(status: VISIBLE_TO_EMPLOYEE)
             .joins(:payroll_entries)
             .where(payroll_entries: { user_id: user.id })
      else
        scope.none
      end
    end
  end

  private

  def managing?
    return false unless same_business?
    super_admin? || accountant? || area_manager? || branch_manager?
  end

  def visible_to_employee?
    employee? && same_business? && (record.finalized? || record.paid?) &&
      record.payroll_entries.exists?(user_id: user.id)
  end
end
