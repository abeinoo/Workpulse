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

  TIMELINE_PER_PAGE = 20

  def show
    authorize @user
    @active_salary_profile = @user.active_salary_profile
    @salary_profiles = @user.salary_profiles.order(effective_from: :desc)

    load_shift_timeline
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

  # ── Shift timeline helpers ────────────────────────────────────────────────

  # Populates all @timeline_* instance variables consumed by the partial.
  # Supports: tab (active/upcoming/historical/all), branch_id, shift_id,
  # from/to date range, and page.  All scoped strictly to @user.
  def load_shift_timeline
    @timeline_tab       = params[:timeline_tab].presence_in(
                            %w[active upcoming historical all]
                          ) || "all"
    @timeline_branch_id = params[:timeline_branch_id].presence
    @timeline_shift_id  = params[:timeline_shift_id].presence
    @timeline_from      = params[:timeline_from].presence
    @timeline_to        = params[:timeline_to].presence

    # ── Base scope ────────────────────────────────────────────────────────
    base = @user.shift_assignments

    # ── Tab filter ────────────────────────────────────────────────────────
    today = Date.current
    base = case @timeline_tab
           when "active"
             base.current
           when "upcoming"
             base.upcoming
           when "historical"
             base.expired
           else
             base
           end

    # ── Column filters ────────────────────────────────────────────────────
    base = base.where(branch_id: @timeline_branch_id)  if @timeline_branch_id
    base = base.where(shift_id:  @timeline_shift_id)   if @timeline_shift_id
    base = base.where("effective_from >= ?", @timeline_from) if @timeline_from.present?
    base = base.where("effective_from <= ?", @timeline_to)   if @timeline_to.present?

    @timeline_active_filters = [
      @timeline_branch_id, @timeline_shift_id, @timeline_from, @timeline_to
    ].count(&:present?)

    # ── Filter drop-down data ─────────────────────────────────────────────
    @timeline_branches = Branch.for_business(current_user.business).active.order(:name)
    @timeline_shifts   = Shift.for_business(current_user.business).active.order(:name)

    # ── Pagination ────────────────────────────────────────────────────────
    @timeline_total = base.count
    @timeline_pages = [(@timeline_total.to_f / TIMELINE_PER_PAGE).ceil, 1].max
    @timeline_page  = [[params[:timeline_page].to_i, 1].max, @timeline_pages].min

    # ── Eager-loaded paginated slice ──────────────────────────────────────
    @shift_assignments = base
      .includes(:shift, :branch, :created_by, :ended_by)
      .order(effective_from: :desc)
      .offset((@timeline_page - 1) * TIMELINE_PER_PAGE)
      .limit(TIMELINE_PER_PAGE)
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
