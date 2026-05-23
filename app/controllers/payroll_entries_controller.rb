class PayrollEntriesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_period_and_entry

  def show
    authorize @entry

    all_items          = @entry.payroll_line_items.to_a
    @deductions        = all_items.select { |li| li.deduction? && !li.manual_deduction? }
    @manual_deductions = all_items.select(&:manual_deduction?)
    @additions         = all_items.select(&:addition?)
    @attendance        = load_attendance_stats
    @salary_profile    = SalaryProfile.current_for(@entry.user)
    @permission_lookup = load_permission_lookup

    paid_adj_ids = @additions.select { |li| li.already_paid? && li.source_type == "PayrollAdjustment" }
                             .map(&:source_id).compact
    @paid_adjustments = paid_adj_ids.any? ? PayrollAdjustment.where(id: paid_adj_ids).index_by(&:id) : {}
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
      days_present:              @attendance_records.count { |r| %w[present late early_leave].include?(r.status) },
      days_absent:               @attendance_records.count { |r| r.status == "absent" }
    }
  end
end
