class Admin::BiometricPunchLogsController < Admin::BaseController
  # Every action authorizes with BiometricPunchLogPolicy (SEC-M2-8):
  # Admin::BaseController's gate admits view_employees, view_payroll …, but punch
  # logs need manage_devices (the whole business) or view_attendance (its data
  # scope). Records are found through the policy scope, so a log outside it is
  # not found (404).
  #
  # Two branch filters, combined with AND:
  # * branch_id        — Assignment Branch: employees assigned there today
  #                      (unchanged; also narrows the employee list);
  # * actual_branch_id — Actual Branch: where the punch was made, the branch its
  #                      device had when the punch was received; "none" selects
  #                      the logs with no recorded branch (mobile punches,
  #                      devices with no branch, logs from before branches were
  #                      recorded).
  # Both narrow the policy scope; neither widens what the user may see.
  NO_ACTUAL_BRANCH = "none".freeze

  def index
    authorize BiometricPunchLog

    branch_id = params[:branch_id].presence

    @branches        = current_user.business.branches.active.order(:name)
    @actual_branches = current_user.business.branches.order(:name)
    @employees       = employees_scope(branch_id)
    actual_branch_id = actual_branch_filter

    employee_id = params[:employee_id].presence
    employee_id = nil unless employee_id.nil? || @employees.exists?(id: employee_id)

    scope = policy_scope(BiometricPunchLog)
              .includes(:biometric_device, :branch, :employee, :attendance_record)
              .recent

    scope = scope.where(employee_id: ShiftAssignment.user_ids_for_branches(branch_id)) if branch_id
    scope = scope.where(branch_id: actual_branch_id == NO_ACTUAL_BRANCH ? nil : actual_branch_id) if actual_branch_id
    scope = scope.where(employee_id: employee_id)                        if employee_id
    scope = scope.where(biometric_device_id: params[:device_id])         if params[:device_id].present?
    scope = scope.where(action: params[:action_filter])                  if params[:action_filter].present?

    @logs    = scope.limit(100)
    @devices = current_user.business.biometric_devices.order(:name)
  end

  def show
    authorize BiometricPunchLog, :index? # no punch-log permission: the not-authorized redirect, as on the index
    @log = policy_scope(BiometricPunchLog)
             .includes(:biometric_device, :employee, :attendance_record)
             .find(params[:id])
    authorize @log
  end

  private

  # A branch of the business, NO_ACTUAL_BRANCH, or nil (no filter) — an unknown
  # id is ignored, like an employee outside the visible set.
  def actual_branch_filter
    value = params[:actual_branch_id].presence
    return value if value.nil? || value == NO_ACTUAL_BRANCH

    value if @actual_branches.exists?(id: value)
  end

  # Only the employees whose logs the user may see (BiometricPunchLogPolicy).
  def employees_scope(branch_id)
    scope = BiometricPunchLogPolicy.visible_employees(current_user).active
    scope = scope.where(id: ShiftAssignment.user_ids_for_branches(branch_id)) if branch_id
    scope.order(:first_name, :last_name)
  end
end
