class Admin::EmployeeObligationsController < Admin::BaseController
  before_action :set_obligation, only: [ :show, :edit, :update, :pause, :resume, :cancel, :postpone ]

  FILTER_KEYS      = %i[q user_id branch_id obligation_type status start_from start_to balance].freeze
  BALANCE_FILTERS  = %w[outstanding repaid].freeze
  PER_PAGE_OPTIONS = [ 20, 50, 100 ].freeze
  SORTS = {
    "employee"    => "LOWER(users.first_name) %{dir}, LOWER(users.last_name) %{dir}",
    "total"       => "employee_obligations.total_amount %{dir}",
    "remaining"   => "employee_obligations.remaining_amount %{dir}",
    "installment" => "employee_obligations.installment_amount %{dir}",
    "start"       => "employee_obligations.start_year %{dir}, employee_obligations.start_month %{dir}",
    "status"      => "CASE employee_obligations.status " +
                     EmployeeObligation::STATUSES.each_with_index.map { |s, i| "WHEN '#{s}' THEN #{i}" }.join(" ") +
                     " END %{dir}"
  }.freeze

  def index
    authorize EmployeeObligation
    base     = policy_scope(EmployeeObligation)
    @filters = filter_params
    session[:employee_obligation_filters] = @filters

    # Distinguishes "nothing to show at all" from "no filter matches".
    @any_obligations = base.exists?

    scope = base.search(@filters[:q])
                .for_employee(@filters[:user_id])
                .for_branch(@filters[:branch_id])
                .of_type(@filters[:obligation_type])
                .with_status(@filters[:status])
                .starting_on_or_after(parsed_month(@filters[:start_from]))
                .starting_on_or_before(parsed_month(@filters[:start_to]))
    scope = scope.with_outstanding_balance if @filters[:balance] == "outstanding"
    scope = scope.fully_repaid             if @filters[:balance] == "repaid"

    # Summary covers the whole filtered result set (same scope as the table,
    # before sorting/pagination), so it matches whatever the viewer filtered to.
    status_counts = scope.group(:status).count
    outstanding   = scope.with_outstanding_balance
    @summary = {
      total:             status_counts.values.sum,
      active:            status_counts["active"].to_i,
      completed:         status_counts["completed"].to_i,
      outstanding_total: outstanding.sum(:remaining_amount),
      outstanding_count: outstanding.count
    }

    @sort     = SORTS.key?(params[:sort]) ? params[:sort] : nil
    @dir      = params[:dir] == "asc" ? "asc" : "desc"
    @per_page = PER_PAGE_OPTIONS.include?(params[:per].to_i) ? params[:per].to_i : PER_PAGE_OPTIONS.first

    @total_count = scope.count
    @total_pages = [ (@total_count.to_f / @per_page).ceil, 1 ].max
    @page        = params[:page].to_i.clamp(1, @total_pages)

    ordered = if @sort
      scope.joins(:user).order(Arel.sql(format(SORTS[@sort], dir: @dir)), id: :desc)
    else
      scope.order(created_at: :desc, id: :desc)
    end

    @obligations = ordered.includes(user: { profile_photo_attachment: :blob })
                          .offset((@page - 1) * @per_page)
                          .limit(@per_page)

    # Filter options are limited to what the viewer can already see.
    visible_user_ids  = base.select(:user_id)
    @filter_employees = current_user.business.users.where(id: visible_user_ids).order(:first_name, :last_name).to_a
    @filter_branches  = current_user.business.branches
                                    .where(id: ShiftAssignment.current.where(user_id: visible_user_ids).select(:branch_id))
                                    .order(:name).to_a
    # Start months that actually occur, newest first, as [year, month] pairs.
    @filter_months    = base.distinct.pluck(:start_year, :start_month).sort.reverse
  end

  def show
    authorize @obligation
    # Return to the index with the viewer's last search/filters intact.
    @back_path = admin_employee_obligations_path(session[:employee_obligation_filters].presence || {})
  end

  def new
    @obligation = EmployeeObligation.new(user_id: params[:user_id])
    authorize @obligation
    load_employees
  end

  def create
    @obligation = EmployeeObligation.new(obligation_params)
    @obligation.business         = current_user.business
    @obligation.created_by       = current_user
    @obligation.remaining_amount = @obligation.total_amount
    @obligation.installments_count = derive_installments_count(@obligation)
    authorize @obligation

    if @obligation.save
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.created")
    else
      load_employees
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    authorize @obligation
    if @obligation.payroll_locked?
      redirect_to admin_employee_obligation_path(@obligation),
                  alert: t("admin.employee_obligations.locked_for_edit")
      return
    end
    load_employees
  end

  def update
    authorize @obligation
    authorize_reassignment!
    if @obligation.payroll_locked?
      redirect_to admin_employee_obligation_path(@obligation),
                  alert: t("admin.employee_obligations.locked_for_edit")
      return
    end

    result = Payroll::ObligationEditor.call(
      obligation_id: @obligation.id,
      business:      current_user.business,
      actor:         current_user,
      attrs:         obligation_params
    )

    if result.ok?
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.updated")
    else
      @obligation = result.obligation
      load_employees
      render :edit, status: :unprocessable_entity
    end
  end

  def pause
    authorize @obligation
    if @obligation.active?
      change_status_and_refresh_payroll!(:paused)
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.paused")
    else
      redirect_to admin_employee_obligation_path(@obligation),
                  alert: t("admin.employee_obligations.cannot_pause")
    end
  end

  def resume
    authorize @obligation
    if @obligation.paused?
      change_status_and_refresh_payroll!(:active)
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.resumed")
    else
      redirect_to admin_employee_obligation_path(@obligation),
                  alert: t("admin.employee_obligations.cannot_resume")
    end
  end

  def cancel
    authorize @obligation
    if @obligation.active? || @obligation.paused?
      change_status_and_refresh_payroll!(:cancelled)
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.cancelled")
    else
      redirect_to admin_employee_obligation_path(@obligation),
                  alert: t("admin.employee_obligations.cannot_cancel")
    end
  end

  def postpone
    authorize @obligation
    result = Payroll::ObligationInstallmentPostponer.call(
      obligation_id:      @obligation.id,
      business:           current_user.business,
      actor:              current_user,
      year:               params[:year],
      month:              params[:month],
      postponement_type:  params[:postponement_type],
      reason:             params[:reason]
    )

    if result.ok?
      redirect_to admin_employee_obligation_path(@obligation),
                  notice: t("admin.employee_obligations.postponement.success")
    else
      redirect_to admin_employee_obligation_path(@obligation), alert: result.error
    end
  end

  private

  # Only active obligations are deducted (Payroll::ObligationDeductor), so a
  # status change must rebuild the employee's open (non-finalized) payroll
  # entries too — otherwise a draft keeps deducting a paused/cancelled
  # obligation, or misses a resumed one (AP-D4). Atomic with the change.
  def change_status_and_refresh_payroll!(status)
    ActiveRecord::Base.transaction do
      @obligation.update!(status: status)
      Payroll::EntryRecalculator.recalculate_all_open_periods_for(user: @obligation.user, triggered_by: current_user)
    end
  end

  def set_obligation
    @obligation = policy_scope(EmployeeObligation).find(params[:id])
  end

  def obligation_params
    params.require(:employee_obligation).permit(
      :user_id, :obligation_type, :title, :description, :notes,
      :total_amount, :installment_amount,
      :start_month, :start_year, :end_month, :end_year,
      :auto_deduct
    )
  end

  # Present, whitelisted index filters only — also what the filter chips and
  # "remove filter" links are built from.
  def filter_params
    filters = params.permit(*FILTER_KEYS).to_h.symbolize_keys.transform_values { |v| v.to_s.strip }.compact_blank
    filters.delete(:balance) unless BALANCE_FILTERS.include?(filters[:balance])
    filters
  end

  # "YYYY-MM" → first day of that month (the scopes compare by month only).
  def parsed_month(value)
    return nil unless value.to_s.match?(/\A\d{4}-\d{2}\z/)

    Date.iso8601("#{value}-01")
  rescue ArgumentError
    nil
  end

  # Only employees inside the actor's manage_obligations scope can be chosen
  # (the same rule EmployeeObligationPolicy#create? enforces).
  def load_employees
    @employees = current_user.business.users.active
                             .where(id: policy(EmployeeObligation).manageable_employee_ids)
                             .order(:first_name, :last_name)
  end

  # Moving an obligation to another employee needs the same scope as creating
  # one for that employee (SEC-M2-4 follow-up).
  def authorize_reassignment!
    target_id = params.dig(:employee_obligation, :user_id)
    return if target_id.blank? || target_id.to_i == @obligation.user_id

    authorize EmployeeObligation.new(business: current_user.business, user_id: target_id), :create?
  end

  def derive_installments_count(obligation)
    total = obligation.total_amount.to_f
    installment = obligation.installment_amount.to_f
    return 1 if total <= 0 || installment <= 0
    (total / installment).ceil
  end
end
