class Admin::BranchesController < Admin::BaseController
  def index
    authorize Branch
    @branches = policy_scope(Branch).order(:name)
  end

  def show
    @branch = find_branch
    authorize @branch
    today = Date.current

    # Branch membership is shift-driven: employees currently assigned to this branch
    # via an active ShiftAssignment.
    @employees = User.where(id: ShiftAssignment.user_ids_for_branches([ @branch.id ]), active: true)
                     .includes(:permission_role, profile_photo_attachment: :blob)
                     .order(:first_name, :last_name)
    @branch_manager = @branch.branch_manager

    @today_records = @branch.attendance_records
                             .for_date(today)
                             .includes({ user: { profile_photo_attachment: :blob } }, shift_assignment: :shift)
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
                                 .includes({ user: { profile_photo_attachment: :blob } }, shift: :penalty_rules)
                                 .order(:id)

    load_payroll_summary(today)

    # What other domains still record at the branch, shown (never enforced) in
    # the deactivation dialog — through the OA contract, never their tables (BUG-029).
    @deactivation_notices = @branch.active? ? OrganizationAccess::BranchDeactivationNotices.notices_for(branch: @branch) : []

    branch_user_ids = ShiftAssignment.user_ids_for_branches([ @branch.id ])

    @pending_requests = EmployeeRequest
                          .where(user_id: branch_user_ids, status: :pending)
                          .includes(user: { profile_photo_attachment: :blob })
                          .order(created_at: :desc)
                          .limit(10)

    @recent_requests = EmployeeRequest
                         .where(user_id: branch_user_ids, status: [ :approved, :rejected ])
                         .includes({ user: { profile_photo_attachment: :blob } }, :reviewed_by)
                         .order(updated_at: :desc)
                         .limit(10)
  end

  def new
    @branch = current_user.business.branches.build
    authorize @branch
    load_managers
  end

  # The branch (and, for a sales branch, its branch warehouse) is created by
  # OrganizationAccess::CreateBranch in one transaction.
  def create
    @branch = current_user.business.branches.build
    authorize @branch
    result = OrganizationAccess::CreateBranch.new(actor: current_user, attributes: branch_params.to_h,
                                                  terminal_rows: pos_terminal_rows).call
    @branch = result.record

    if result.ok?
      redirect_to admin_branch_path(@branch), notice: t("flash.branch_created")
    else
      load_managers
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @branch = find_branch
    authorize @branch
    load_managers
  end

  # A non-sales -> sales change provisions the branch warehouse in the same
  # transaction (OrganizationAccess::UpdateBranch).
  def update
    @branch = find_branch
    authorize @branch
    result = OrganizationAccess::UpdateBranch.new(@branch.id, actor: current_user, attributes: branch_params.to_h,
                                                  terminal_rows: pos_terminal_rows).call
    @branch = result.record

    if result.ok?
      redirect_to admin_branch_path(@branch), notice: t("flash.branch_updated")
    else
      load_managers
      render :edit, status: :unprocessable_entity
    end
  end

  # Permanent deletion is for never-used branches only; anything with history is
  # refused with an explanation and must be deactivated (BUG-026).
  def destroy
    @branch = find_branch
    authorize @branch
    result = OrganizationAccess::DeleteBranch.new(@branch.id, actor: current_user, reason: params[:reason]).call
    if result.ok?
      redirect_to admin_branches_path, notice: t("flash.branch_deleted"), status: :see_other
    else
      redirect_with_lifecycle_error(result)
    end
  end

  def deactivate
    @branch = find_branch
    authorize @branch
    result = OrganizationAccess::DeactivateBranch.new(@branch.id, actor: current_user, reason: params[:reason]).call
    if result.ok?
      redirect_to admin_branch_path(@branch), notice: t("flash.branch_deactivated"), status: :see_other
    else
      redirect_with_lifecycle_error(result)
    end
  end

  def reactivate
    @branch = find_branch
    authorize @branch
    result = OrganizationAccess::ReactivateBranch.new(@branch.id, actor: current_user, reason: params[:reason]).call
    if result.ok?
      redirect_to admin_branch_path(@branch), notice: t("flash.branch_reactivated"), status: :see_other
    else
      redirect_with_lifecycle_error(result)
    end
  end

  private

  # The branch's payroll for this month: per-employee pay, so shown only with
  # view_payroll and only the entries its data scope allows (PayrollEntryPolicy
  # scope) — managing branches alone shows none. Audited when shown.
  def load_payroll_summary(today)
    @show_payroll_summary = current_user.can?(:view_payroll)
    return unless @show_payroll_summary

    @payroll_period  = @branch.payroll_periods.find_by(period_month: today.month, period_year: today.year)
    @payroll_entries = if @payroll_period
      policy_scope(PayrollEntry).where(payroll_period: @payroll_period)
                                .includes(user: { profile_photo_attachment: :blob }).to_a
    else
      []
    end
    Payroll::EntryViewAudit.record(actor: current_user, entries: @payroll_entries, source: "branch_payroll_summary")
  end

  def find_branch
    current_user.business.branches.find(params[:id])
  end

  def redirect_with_lifecycle_error(result)
    redirect_to admin_branch_path(@branch), alert: t("admin.branches.lifecycle.errors.#{result.error}"), status: :see_other
  end

  def load_managers
    all_active = current_user.business.users.active.order(:first_name, :last_name)
    @managers      = all_active
    @area_managers = all_active
  end

  # `active` is not editable here: deactivation / reactivation go through their
  # own actions (reason, last-active-branch rule, audit — BUG-026).
  def branch_params
    params.require(:branch).permit(
      :name, :address, :phone_number, :branch_type,
      :branch_manager_id, :area_manager_id,
      :geolocation_enabled, :latitude, :longitude, :radius_meters
    )
  end

  POS_TERMINAL_FIELDS = %i[id terminal_id label active _destroy].freeze

  # The permitted rows as plain hashes, in submitted order. An index-keyed hash
  # becomes its rows; a single row (an "id" at the top level) stays one row —
  # the same reading nested attributes gave the raw params.
  def pos_terminal_rows
    rows = params.require(:branch).permit(pos_terminals_attributes: POS_TERMINAL_FIELDS)[:pos_terminals_attributes]
    return if rows.nil?

    rows = rows.key?(:id) ? [ rows ] : rows.values if rows.is_a?(ActionController::Parameters)
    rows.map(&:to_hash)
  end
end
