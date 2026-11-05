class SalaryPaymentHoldPolicy < ApplicationPolicy
  # Salary Payment Holds — within the payroll the actor may already see, never
  # their own:
  # * view (status, reason, history, held amounts): view_salary_payment_holds,
  #   the employee inside both its scope and the actor's payroll visibility
  #   (PayrollEntryPolicy.visible_employees);
  # * create / release: manage_salary_payment_holds, the employee also inside
  #   its scope. Release only an active hold.
  # The hold must belong to the actor's business. `record` is a hold, persisted
  # or SalaryPaymentHold.new(business_id:, user_id:) for "may I place one?".

  def show?    = hold? && same_business? && self.class.viewable_employees(user).exists?(id: record.user_id)
  def create?  = hold? && same_business? && self.class.manageable_employees(user).exists?(id: record.user_id)
  def release? = create? && record.persisted? && record.active?

  def self.viewable_employees(user)
    return User.none unless user.can?(:view_salary_payment_holds)

    PayrollEntryPolicy.visible_employees(user)
                      .where(id: EmployeeScope.new(user).for_permissions(:view_salary_payment_holds).select(:id))
                      .where(business_id: user.business_id).where.not(id: user.id)
  end

  def self.manageable_employees(user)
    return User.none unless user.can?(:manage_salary_payment_holds)

    viewable_employees(user).where(id: EmployeeScope.new(user).for_permissions(:manage_salary_payment_holds).select(:id))
  end

  private

  def hold? = record.is_a?(SalaryPaymentHold)
end
