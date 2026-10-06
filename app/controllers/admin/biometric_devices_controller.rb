class Admin::BiometricDevicesController < Admin::BaseController
  before_action :set_device, only: [ :show, :edit, :update, :destroy, :regenerate_token ]

  def index
    authorize BiometricDevice
    @devices = current_user.business.biometric_devices.order(:name)
  end

  def show
    authorize @device
  end

  def new
    @device = current_user.business.biometric_devices.build
    authorize @device
  end

  def create
    @device = current_user.business.biometric_devices.build(device_params)
    authorize @device
    if @device.save
      redirect_to admin_biometric_device_path(@device), notice: t("flash.biometric_device_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @device
  end

  def update
    authorize @device
    if @device.update(device_params)
      redirect_to admin_biometric_device_path(@device), notice: t("flash.biometric_device_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @device
    @device.destroy
    redirect_to admin_biometric_devices_path, notice: t("flash.biometric_device_deleted")
  end

  def regenerate_token
    authorize @device
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
