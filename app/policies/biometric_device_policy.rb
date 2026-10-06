class BiometricDevicePolicy < ApplicationPolicy
  # A device's token authenticates POST /api/v1/attendance/punch for any active
  # employee of its business, so every device action — including viewing the
  # token — requires manage_devices (SEC-M2-1). Admin::BaseController's gate
  # alone is not an authorization rule: it admits view_employees, view_payroll …
  def index?            = can?(:manage_devices)
  def show?             = manage?
  def create?           = manage?
  def update?           = manage?
  def destroy?          = manage?
  def regenerate_token? = manage?

  private

  def manage?
    can?(:manage_devices) && same_business?
  end
end
