class Admin::BranchesController < Admin::BaseController
  def index
    @branches = current_user.business.branches.order(:name)
  end

  def show
    @branch = find_branch
    today = Date.current

    @employees = @branch.users.where(active: true).order(:first_name, :last_name)
    @branch_manager = @branch.branch_manager

    @today_records = @branch.attendance_records
                             .for_date(today)
                             .includes(:user, shift_assignment: :shift)
    @today_records_by_user = @today_records.index_by(&:user_id)

    today_arr = @today_records_by_user.values
    @attendance_stats = {
      total:            @employees.count,
      checked_in:       today_arr.count { |r| r.check_in_at.present? },
      missing_checkout: today_arr.count { |r| r.check_in_at.present? && r.check_out_at.nil? },
      late:             today_arr.count(&:late?),
      early_leave:      today_arr.count(&:early_leave?)
    }

    @shift_assignments = @branch.shift_assignments.current
                                 .includes(:user, shift: :penalty_rules)
                                 .order(:id)

    @payroll_period = @branch.payroll_periods
                              .where(period_month: today.month, period_year: today.year)
                              .includes(payroll_entries: :user)
                              .first

    branch_user_ids = UserBranch.where(branch: @branch).select(:user_id)

    @pending_requests = EmployeeRequest
                          .where(user_id: branch_user_ids, status: :pending)
                          .includes(:user)
                          .order(created_at: :desc)
                          .limit(10)

    @recent_requests = EmployeeRequest
                         .where(user_id: branch_user_ids, status: [ :approved, :rejected ])
                         .includes(:user, :reviewed_by)
                         .order(updated_at: :desc)
                         .limit(10)
  end

  def new
    @branch = current_user.business.branches.build
    load_managers
  end

  def create
    @branch = current_user.business.branches.build(branch_params)
    if @branch.save
      redirect_to admin_branch_path(@branch), notice: t("flash.branch_created")
    else
      load_managers
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @branch = find_branch
    load_managers
  end

  def update
    @branch = find_branch
    if @branch.update(branch_params)
      redirect_to admin_branch_path(@branch), notice: t("flash.branch_updated")
    else
      load_managers
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    find_branch.destroy
    redirect_to admin_branches_path, notice: t("flash.branch_removed")
  end

  private

  def find_branch
    current_user.business.branches.find(params[:id])
  end

  def load_managers
    @managers = current_user.business.users
                             .where(role: :branch_manager, active: true)
                             .order(:first_name, :last_name)
    @area_managers = current_user.business.users
                                  .where(role: :area_manager, active: true)
                                  .order(:first_name, :last_name)
  end

  def branch_params
    params.require(:branch).permit(
      :name, :address, :phone_number, :active,
      :branch_manager_id, :area_manager_id,
      :geolocation_enabled, :latitude, :longitude, :radius_meters
    )
  end
end
