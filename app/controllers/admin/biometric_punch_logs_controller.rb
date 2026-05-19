class Admin::BiometricPunchLogsController < Admin::BaseController
  def index
    scope = current_user.business.biometric_punch_logs
                        .includes(:biometric_device, :employee, :attendance_record)
                        .recent

    scope = scope.where(employee: User.find_by(id: params[:employee_id])) if params[:employee_id].present?
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
end
