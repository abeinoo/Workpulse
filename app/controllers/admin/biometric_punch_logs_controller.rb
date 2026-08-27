class Admin::BiometricPunchLogsController < Admin::BaseController
  def index
    branch_id = params[:branch_id].presence

    @branches  = current_user.business.branches.active.order(:name)
    @employees = employees_scope(branch_id)

    employee_id = params[:employee_id].presence
    employee_id = nil unless employee_id.nil? || @employees.exists?(id: employee_id)

    scope = current_user.business.biometric_punch_logs
                        .includes(:biometric_device, :employee, :attendance_record)
                        .recent

    scope = scope.where(employee_id: ShiftAssignment.user_ids_for_branches(branch_id)) if branch_id
    scope = scope.where(employee_id: employee_id)                        if employee_id
    scope = scope.where(biometric_device_id: params[:device_id])         if params[:device_id].present?
    scope = scope.where(action: params[:action_filter])                  if params[:action_filter].present?

    @logs    = scope.limit(100)
    @devices = current_user.business.biometric_devices.order(:name)
  end

  def show
    @log = current_user.business.biometric_punch_logs
                       .includes(:biometric_device, :employee, :attendance_record)
                       .find(params[:id])
  end

  private

  def employees_scope(branch_id)
    scope = current_user.business.users.active
    scope = scope.where(id: ShiftAssignment.user_ids_for_branches(branch_id)) if branch_id
    scope.order(:first_name, :last_name)
  end
end
