class Admin::UsersController < Admin::BaseController
  before_action :set_user, only: [ :show, :edit, :update, :destroy, :transfer_ownership, :toggle_active ]

  def index
    authorize User
    @status_filter = params[:status].presence_in(%w[active inactive]) || "active"
    scope = policy_scope(User)
              .includes(:permission_role, profile_photo_attachment: :blob)
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
  end

  def create
    @user = current_user.business.users.new
    authorize @user

    p = user_params
    p.delete(:remove_profile_photo)
    p.delete(:remove_national_id_front)
    p.delete(:remove_national_id_back)
    warehouse_ids = p.delete(:assigned_warehouse_ids)
    @user.assign_attributes(p.except(:permission_role_id))
    assign_warehouse_access(@user, warehouse_ids)

    if !assign_role(@user, p)
      render :new, status: :unprocessable_entity
    elsif @user.save
      redirect_to admin_users_path, notice: t("flash.employee_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  TIMELINE_PER_PAGE = 20

  def show
    authorize @user
    load_salary

    # Performance tab — finalized reviews for this employee, newest first.
    if current_user.can?(:view_monthly_reviews)
      @performance_reviews = @user.performance_reviews
                                  .includes(:department)
                                  .finalized_reviews.recent_first.limit(12)
    end

    load_shift_timeline
  end

  def edit
    authorize @user
  end

  def update
    authorize @user

    p = user_params
    removals = p.extract!(:remove_profile_photo, :remove_national_id_front, :remove_national_id_back)
    warehouse_ids = p.delete(:assigned_warehouse_ids)
    @user.assign_attributes(p.except(:permission_role_id))
    assign_warehouse_access(@user, warehouse_ids)

    if !assign_role(@user, p)
      render :edit, status: :unprocessable_entity
    elsif @user.save
      %i[profile_photo national_id_front national_id_back].each do |name|
        @user.public_send(name).purge if removals["remove_#{name}"] == "1"
      end
      redirect_to admin_users_path, notice: t("flash.employee_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @user
    if @user == current_user
      return redirect_to admin_users_path, alert: t("flash.cannot_delete_self")
    end

    result = OrganizationAccess::DeleteUser.new(@user.id, actor: current_user).call
    if result.ok?
      redirect_to admin_users_path, notice: t("flash.employee_removed")
    else
      # Back to the list, where the employee's Deactivate action is.
      redirect_to admin_users_path, alert: t("flash.employee_delete_refused.#{result.error}", name: @user.full_name)
    end
  end

  def transfer_ownership
    authorize @user
    current_user.business.update!(owner: @user)
    redirect_to admin_user_path(@user), notice: t("flash.ownership_transferred")
  end

  def toggle_active
    # Checked before authorize so the owner case keeps its specific message
    # (UserPolicy#toggle_active? also refuses it).
    if @user.owner?
      return redirect_to admin_users_path, alert: t("flash.cannot_deactivate_owner")
    end

    authorize @user

    @user.update!(active: !@user.active?)
    flash_key = @user.active? ? :user_activated : :user_deactivated
    redirect_to admin_users_path, notice: t("flash.#{flash_key}", name: @user.full_name)
  end

  private

  def set_user
    @user = current_user.business.users.find(params[:id])
  end

  # The employee page shows salary only under SalaryProfilePolicy, never
  # because the employee page itself is visible (SEC-M2-5): the current profile
  # only (no history), audited when shown. The obligations card is read in the
  # view — the documented Attendance & Payroll exception
  # (attendance_payroll_obligation_boundary_spec) — under EmployeeObligationPolicy.
  def load_salary
    probe = SalaryProfile.new(user_id: @user.id) # standalone: never built into @user.salary_profiles
    @salary_visible    = policy(probe).view_salary?
    @salary_manageable = policy(probe).create?
    # The salary in force today (the scope resolves the effective profile).
    @active_salary_profile = @salary_visible ? policy_scope(SalaryProfile).find_by(user: @user) : nil
    Salary::ViewAudit.record(actor: current_user, employee: @user, profiles: [ @active_salary_profile ],
                             source: "admin_employee_page")
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
      .includes(:shift, :branch, :created_by, :ended_by, :source_template, :rule_profile)
      .order(effective_from: :desc)
      .offset((@timeline_page - 1) * TIMELINE_PER_PAGE)
      .limit(TIMELINE_PER_PAGE)

    # ── Next-assignment lookup for active temporary assignments ───────────
    # For each active assignment that has an end date, find the next one
    # starting after it ends so we can show "Resumes: ShiftName from DATE".
    active_bounded = @shift_assignments.select { |a| a.effective_to.present? && a.current? }
    if active_bounded.any?
      @next_assignments = active_bounded.each_with_object({}) do |a, hash|
        hash[a.id] = @user.shift_assignments
                          .where("effective_from > ?", a.effective_to)
                          .includes(:shift)
                          .order(:effective_from)
                          .first
      end
    else
      @next_assignments = {}
    end
  end

  # Attribute tiers come from UserPolicy#permitted_attributes: self-service
  # profile fields vs employment, account-status/access and role fields
  # (OA-S1/S3/S5). Anything else in the request is dropped.
  def user_params
    params.require(:user).permit(*policy(@user).permitted_attributes)
  end

  # Warehouse access (Inventory & Purchasing) goes through the Organization &
  # Access UserWarehouseAccess contract, at the point the attribute was assigned
  # before (Batch W): after the other attributes, before the role check and the
  # save — for a persisted user it applies immediately, as it always has.
  # Absent from the request (or not permitted by the account tier): untouched.
  def assign_warehouse_access(user, warehouse_ids)
    OrganizationAccess::UserWarehouseAccess.assign(user: user, warehouse_ids: warehouse_ids) unless warehouse_ids.nil?
  end

  # Stages a requested role change on the (possibly unsaved) user, saved with
  # the rest of the form. The decision is OrganizationAccess::RoleAssignmentRule
  # — the same rule as the role screen (OA-S2/S3). An unchanged value is a no-op.
  def assign_role(user, attributes)
    return true unless attributes.key?(:permission_role_id)

    requested_id = attributes[:permission_role_id].presence&.to_i
    return true if requested_id == user.permission_role_id

    decision = OrganizationAccess::RoleAssignmentRule.decide(actor: current_user, user: user, role_id: requested_id)
    unless decision.allowed?
      user.errors.add(:permission_role_id, t("admin.users.errors.cannot_assign_role"))
      return false
    end

    user.permission_role = decision.role
    true
  end
end
