class Admin::BiometricDevicesController < Admin::BaseController
  before_action :set_device, only: [:show, :edit, :update, :destroy, :regenerate_token]

  def index
    @devices = current_user.business.biometric_devices.order(:name)
  end

  def show; end

  def new
    @device = BiometricDevice.new
  end

  def create
    @device = current_user.business.biometric_devices.build(device_params)
    if @device.save
      redirect_to admin_biometric_device_path(@device), notice: t("flash.biometric_device_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @device.update(device_params)
      redirect_to admin_biometric_device_path(@device), notice: t("flash.biometric_device_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @device.destroy
    redirect_to admin_biometric_devices_path, notice: t("flash.biometric_device_deleted")
  end

  def regenerate_token
    @device.regenerate_token!
    redirect_to admin_biometric_device_path(@device), notice: t("flash.token_regenerated")
  end

  private

  def set_device
    @device = current_user.business.biometric_devices.find(params[:id])
  end

  def device_params
    params.require(:biometric_device).permit(:name, :location_note, :active)
  end
end
