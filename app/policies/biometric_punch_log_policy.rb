class BiometricPunchLogPolicy < ApplicationPolicy
  # Punch logs (SEC-M2-8; decisions D-S8-1 / D-S8-2) carry an employee's punch
  # times, the source IP address and the raw device payload. Admin::BaseController's
  # gate alone is not an authorization rule (it admits view_employees,
  # view_payroll, manage_evaluation_templates …), so:
  # * manage_devices — every punch log of the business (device troubleshooting;
  #   a global, non-scopable permission);
  # * view_attendance — only the logs of employees inside the configured
  #   view_attendance scope, else the hierarchy default (own + managed), exactly
  #   as AttendanceRecordPolicy::Scope;
  # * anyone else — none.
  # The detail page is protected by the same rule (D-S8-2: no field-level
  # restriction).
  def index? = can?(:manage_devices) || can?(:view_attendance)
  def show?  = record.is_a?(BiometricPunchLog) && index? && Scope.new(user, BiometricPunchLog).resolve.exists?(id: record.id)

  # The employees whose punch logs the user may see — the employee filter of the
  # punch-log screen: every employee of the business for manage_devices, else
  # the view_attendance scope (configured, or own + managed).
  def self.visible_employees(user)
    employees = user.business.users
    return employees if user.can?(:manage_devices)
    return employees.none unless user.can?(:view_attendance)

    in_scope = EmployeeScope.new(user).for_permissions(:view_attendance).select(:id)
    employees.where(id: in_scope).or(employees.where(id: user.id))
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.where(business: user.business)
      return base if user.can?(:manage_devices)
      return scope.none unless user.can?(:view_attendance)

      configured = user.scope_for(:view_attendance)
      if configured
        filter_by_data_scope(base, configured, user_id_column: :employee_id)
      else
        managed_ids = EmployeeScope.new(user).relation.select(:id)
        base.where(employee_id: user.id).or(base.where(employee_id: managed_ids))
      end
    end
  end
end
