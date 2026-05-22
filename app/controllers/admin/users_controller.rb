class Admin::UsersController < Admin::BaseController
  before_action :set_user, only: [ :show, :edit, :update, :destroy, :transfer_ownership ]

  def index
    authorize User
    @users = policy_scope(User)
               .where.not(id: current_user.id)
               .includes(:manager)
               .order(:first_name, :last_name)
  end

  def new
    @user = current_user.business.users.new
    authorize @user
    load_managers
  end

  def create
    @user = current_user.business.users.new(user_params)
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

    if @user.update(user_params)
      redirect_to admin_users_path, notice: t("flash.employee_updated")
    else
      load_managers
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @user
    @user.destroy
    redirect_to admin_users_path, notice: t("flash.employee_removed")
  end

  def transfer_ownership
    authorize @user
    current_user.business.update!(owner: @user)
    redirect_to admin_user_path(@user), notice: t("flash.ownership_transferred")
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
      :identity_card_number, :identity_card_expiry_date,
      :allow_mobile_attendance, :allow_biometric_attendance,
      :emergency_contact_name, :emergency_contact_phone, :emergency_contact_relationship
    )
  end
end
