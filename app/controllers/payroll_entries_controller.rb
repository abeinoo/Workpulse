class PayrollEntriesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_period_and_entry

  def show
    authorize @entry

    all_items          = @entry.payroll_line_items.to_a
    @additions         = all_items.select(&:addition?)
    @attendance        = load_attendance_stats
    @salary_profile    = SalaryProfile.current_for(@entry.user)
    @permission_lookup = load_permission_lookup

    deductions         = all_items.select(&:deduction?)
    @effective_dates   = load_effective_dates(deductions)
    @deductions        = deductions.sort_by { |li| [ @effective_dates[li.id], li.item_type, li.id ] }

    paid_adj_ids = @additions.select { |li| li.already_paid? && li.source_type == "PayrollAdjustment" }
                             .map(&:source_id).compact
    @paid_adjustments = paid_adj_ids.any? ? PayrollAdjustment.where(id: paid_adj_ids).index_by(&:id) : {}
  end

  def override_overtime
    authorize @entry, :override_overtime?

    result = Payroll::OvertimeOverrider.call(
      entry:  @entry,
      mode:   params[:mode],
      value:  params[:value],
      reason: params[:reason],
      actor:  current_user
    )

    redirect_to payroll_period_payroll_entry_path(@period, @entry),
                **(result.success? ? { notice: t("payroll.overtime_override.flash.updated") }
                                   : { alert: result.error })
  end

  def mark_reviewed
    authorize @entry, :mark_reviewed?

    result = Payroll::EntryReviewClearer.call(entry: @entry, actor: current_user)

    redirect_to payroll_period_payroll_entry_path(@period, @entry),
                **(result.success? ? { notice: t("payroll.needs_review.flash.cleared") }
                                   : { alert: result.error })
  end

  private

  def set_period_and_entry
    @period = policy_scope(PayrollPeriod).find(params[:payroll_period_id])
    @entry  = policy_scope(PayrollEntry)
                .includes(:payroll_line_items, :payroll_period)
                .where(payroll_period: @period)
                .find(params[:id])
  end

  def load_permission_lookup
    EmployeeRequest
      .where(user: @entry.user, status: "approved", affects_payroll: true)
      .where(request_type: %w[late_permission early_leave])
      .where(requested_for_date: @period.period_start..@period.period_end)
      .each_with_object({}) do |req, hash|
        hash[[req.request_type, req.requested_for_date]] = req.duration_minutes.to_i
      end
  end

  def load_attendance_stats
    @attendance_records = AttendanceRecord
                            .active
                            .where(user: @entry.user)
                            .for_period(@period.period_start, @period.period_end)
                            .includes(shift_assignment: :shift)
                            .order(:date)

    # Build a lookup from attendance record id → record so the view can
    # resolve the date for line items whose source_type = 'AttendanceRecord'.
    @source_records = @attendance_records.index_by(&:id)

    # Compute overtime per record in Ruby — records are already loaded.
    overtime_minutes = @entry.payroll_line_items
                             .select { |li| li.item_type == "overtime" }
                             .sum do |li|
                               rec = @source_records[li.source_id]
                               shift = rec&.shift_assignment&.shift
                               shift ? [ rec.worked_minutes.to_i - shift.duration_minutes, 0 ].max : 0
                             end

    {
      total_worked_minutes:      @attendance_records.sum { |r| r.worked_minutes.to_i },
      total_late_minutes:        @attendance_records.sum(&:late_minutes),
      total_early_leave_minutes: @attendance_records.sum(&:early_leave_minutes),
      overtime_minutes:          overtime_minutes,
      days_present:              @attendance_records.count { |r| AttendanceRecord::ATTENDED_STATUSES.include?(r.status) },
      days_absent:               @attendance_records.count { |r| r.status == "absent" }
    }
  end

  # Resolves a display-sort "effective date" per deduction line item, keyed by
  # item id. Attendance-sourced items use the attendance day; advance
  # repayments use when the advance was issued; manager-submitted adjustments
  # (manual deductions, penalties) use when the adjustment was created. Types
  # with no meaningful calendar date of their own (obligation installments,
  # the whole-period absence deduction, and any future type without a source
  # date) fall back to the period start, so they group together at the start
  # of the table rather than being scattered by an arbitrary timestamp.
  def load_effective_dates(items)
    advance_ids    = items.select { |li| li.source_type == "Advance" }.map(&:source_id).compact
    adjustment_ids = items.select { |li| li.source_type == "PayrollAdjustment" }.map(&:source_id).compact

    advances    = advance_ids.any? ? Advance.where(id: advance_ids).index_by(&:id) : {}
    adjustments = adjustment_ids.any? ? PayrollAdjustment.where(id: adjustment_ids).index_by(&:id) : {}

    items.each_with_object({}) do |li, memo|
      memo[li.id] =
        case li.source_type
        when "AttendanceRecord"  then @source_records[li.source_id]&.date
        when "Advance"           then advances[li.source_id]&.issued_at&.to_date
        when "PayrollAdjustment" then adjustments[li.source_id]&.created_at&.to_date
        end || @period.period_start
    end
  end
end
