class Admin::ShiftsController < Admin::BaseController
  # Every action authorizes with ShiftPolicy (SEC-M2-9): Admin::BaseController's
  # gate admits view_employees, view_payroll …, and the form also carries the
  # shift's penalty rules, so changes require manage_shifts. The index keeps
  # its own query (ShiftPolicy::Scope would hide inactive shifts).
  #
  # Penalty rules are owned by Attendance & Payroll: the form's rule rows are
  # staged through the Workforce Shifts::PenaltyRuleSettings contract and saved
  # by the shift's own save, in the same transaction (Pilot 4 — Penalty Rules, M3).
  def index
    authorize Shift
    @shifts = Shift.where(business_id: current_user.business_id).order(:name)
  end

  def show
    @shift = find_shift
    authorize @shift
    @penalty_rules = @shift.penalty_rules.order(:threshold_minutes)
  end

  def new
    @shift = current_user.business.shifts.build
    authorize @shift
  end

  def create
    @shift = current_user.business.shifts.build(shift_params)
    assign_penalty_rules
    authorize @shift
    if @shift.save
      redirect_to admin_shifts_path, notice: t("flash.shift_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @shift = find_shift
    authorize @shift
  end

  def update
    @shift = find_shift
    authorize @shift
    @shift.assign_attributes(shift_params)
    assign_penalty_rules
    if @shift.save
      redirect_to admin_shifts_path, notice: t("flash.shift_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @shift = find_shift
    authorize @shift
    @shift.destroy
    redirect_to admin_shifts_path, notice: t("flash.shift_removed")
  end

  private

  def find_shift
    Shift.where(business_id: current_user.business_id).find(params[:id])
  end

  PENALTY_RULE_FIELDS = %i[id rule_type threshold_minutes deduction_type deduction_value _destroy].freeze

  def shift_params
    params.require(:shift).permit(
      :name, :shift_type, :start_time, :end_time, :required_hours, :overtime_rate_multiplier,
      :max_late_permission_minutes, :max_early_leave_permission_minutes
    )
  end

  # Only when the form sent rule rows, as before.
  def assign_penalty_rules
    rows = penalty_rule_rows
    Shifts::PenaltyRuleSettings.assign(shift: @shift, rows: rows) unless rows.nil?
  end

  # The permitted rows as plain hashes, in submitted order. An index-keyed hash
  # becomes its rows; a single row (an "id" at the top level) stays one row —
  # the same reading nested attributes gave the raw params.
  def penalty_rule_rows
    rows = params.require(:shift).permit(penalty_rules_attributes: PENALTY_RULE_FIELDS)[:penalty_rules_attributes]
    return if rows.nil?

    rows = rows.key?(:id) ? [ rows ] : rows.values if rows.is_a?(ActionController::Parameters)
    rows.map(&:to_hash)
  end
end
