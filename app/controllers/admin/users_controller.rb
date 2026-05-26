class Admin::UsersController < Admin::BaseController
  before_action :set_user, only: [ :show, :edit, :update, :destroy, :transfer_ownership, :toggle_active ]

  def index
    authorize User
    @status_filter = params[:status].presence_in(%w[active inactive]) || "active"
    scope = policy_scope(User)
              .includes(:manager, :permission_role, profile_photo_attachment: :blob)
              .order(:first_name, :last_name)
    @users = case @status_filter
             when "active"   then scope.where(active: true)
             when "inactive" then scope.where(active: false)
             else                 scope
             end
  end

  def new
    @user = current_user.business.users.new
    authorize @user
    load_managers
  end

  def create
    p = user_params
    p.delete(:remove_profile_photo)
    p.delete(:remove_national_id_front)
    p.delete(:remove_national_id_back)
    @user = current_user.business.users.new(p)
    authorize @user

    if @user.save
      redirect_to admin_users_path, notice: t("flash.employee_created")
    else
      load_managers
      render :new, status: :unprocessable_entity
    end
  end

  def show
    authorize @user
    @active_salary_profile = @user.active_salary_profile
    @salary_profiles = @user.salary_profiles.order(effective_from: :desc)
  end

  def edit
    authorize @user
    load_managers
  end

  def update
    authorize @user

    p = user_params
    removals = p.extract!(:remove_profile_photo, :remove_national_id_front, :remove_national_id_back)

    if @user.update(p)
      %i[profile_photo national_id_front national_id_back].each do |name|
        @user.public_send(name).purge if removals["remove_#{name}"] == "1"
      end
      redirect_to admin_users_path, notice: t("flash.employee_updated")
    else
      load_managers
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @user
    if @user == current_user
      return redirect_to admin_users_path, alert: t("flash.cannot_delete_self")
    end
    @user.destroy
    redirect_to admin_users_path, notice: t("flash.employee_removed")
  end

  def transfer_ownership
    authorize @user
    current_user.business.update!(owner: @user)
    redirect_to admin_user_path(@user), notice: t("flash.ownership_transferred")
  end

  def toggle_active
    authorize @user

    if @user.owner?
      return redirect_to admin_users_path, alert: t("flash.cannot_deactivate_owner")
    end

    @user.update!(active: !@user.active?)
    flash_key = @user.active? ? :user_activated : :user_deactivated
    redirect_to admin_users_path, notice: t("flash.#{flash_key}", name: @user.full_name)
  end

  private

  def set_user
    @user = current_user.business.users.find(params[:id])
  end

  def load_managers
    @managers = current_user.business.users.active
                             .where.not(id: @user.id)
                             .order(:first_name, :last_name)
  end

  def user_params
    params.require(:user).permit(
      :first_name, :last_name, :phone_number, :email,
      :employee_code, :active, :manager_id,
      :permission_role_id,
      :job_title, :department, :hire_date, :employment_type,
      :identity_card_number, :identity_card_expiry_date,
      :allow_mobile_attendance, :allow_biometric_attendance,
      :emergency_contact_name, :emergency_contact_phone, :emergency_contact_relationship,
      :profile_photo, :national_id_front, :national_id_back,
      :remove_profile_photo, :remove_national_id_front, :remove_national_id_back
    )
  end
end
