module Payroll
  # Builds one PayrollEntry (+ its line items) for a single user in a payroll period.
  # Called once per user by PeriodGenerator. Returns nil if the user has no salary profile.
  class EntryCalculator
    def self.call(period:, user:, business:)
      new(period: period, user: user, business: business).call
    end

    def initialize(period:, user:, business:)
      @period   = period
      @user     = user
      @business = business
    end

    def call
      rate_calc = Salary::DailyRateCalculator.for(
        user: @user, business: @business, date: @period.period_start
      )
      return nil unless rate_calc.profile

      daily_rate = rate_calc.daily_rate
      profile    = rate_calc.profile
      records    = load_records

      days_worked        = records.count { |r| !r.absent? }
      line_items         = attendance_line_items(records, daily_rate, profile.overtime_multiplier)
      line_items        += absence_line_items(profile, days_worked, daily_rate)
      advance_result     = AdvanceDeductor.call(user: @user)
      obligation_result  = ObligationDeductor.call(user: @user, period: @period)
      adj_items          = adjustment_line_items

      base_salary          = base(profile, daily_rate, days_worked)
      att_deductions       = sum_negatives(line_items)
      adj_deductions       = sum_negatives(adj_items)
      total_deductions     = att_deductions + adj_deductions
      total_overtime       = line_items.select { |i| i[:item_type] == "overtime" }.sum { |i| i[:amount] }
      total_bonuses        = sum_positives(adj_items)
      already_paid_total   = adj_items.select { |i| i[:already_paid] && i[:amount].to_f > 0 }.sum { |i| i[:amount].to_f }
      advances_deducted    = advance_result.total_amount
      obligations_deducted = obligation_result.total_amount
      # already_paid bonuses appear in total_bonuses (for gross reporting) but are
      # subtracted here so they don't inflate the actual payout amount.
      net_salary           = base_salary - total_deductions + total_overtime + total_bonuses \
                             - already_paid_total - advances_deducted - obligations_deducted

      ActiveRecord::Base.transaction do
        entry = @period.payroll_entries.create!(
          user:                 @user,
          salary_type:          profile.salary_type,
          base_salary:          base_salary.round(2),
          working_days:         @period.working_days,
          days_worked:          days_worked,
          total_deductions:     total_deductions.round(2),
          total_overtime:       total_overtime.round(2),
          total_bonuses:        total_bonuses.round(2),
          already_paid_total:   already_paid_total.round(2),
          advances_deducted:    advances_deducted.round(2),
          obligations_deducted: obligations_deducted.round(2),
          net_salary:           net_salary.round(2)
        )

        # Obligation deductions: save snapshot first (triggers balance decrement),
        # then create the line item with the snapshot's id as source.
        obligation_result.items.each do |item|
          snapshot = item.snapshot
          snapshot.save!
          entry.payroll_line_items.create!(item.line_item_attrs.merge(source_id: snapshot.id))
        end

        advance_items = advance_result.line_items.map { |li| li.merge(review_status: "approved") }
        (line_items + advance_items + adj_items).each do |attrs|
          entry.payroll_line_items.create!(attrs)
        end

        entry
      end
    end

    private

    def load_records
      AttendanceRecord
        .includes(shift_assignment: { shift: :penalty_rules })
        .where(user: @user)
        .for_period(@period.period_start, @period.period_end)
    end

    def attendance_line_items(records, daily_rate, overtime_multiplier = nil)
      records.flat_map do |record|
        next [] if record.absent? || !record.checked_out?

        items = []

        # Partial permission reduction: approved late/early-leave requests reduce the
        # penalised minutes proportionally rather than waiving the penalty entirely.
        late_allowed        = EmployeeRequest.approved_minutes(user: @user, date: record.work_date, type: "late_permission")
        early_leave_allowed = EmployeeRequest.approved_minutes(user: @user, date: record.work_date, type: "early_leave")
        effective_late      = [ record.late_minutes.to_i - late_allowed, 0 ].max
        effective_early     = [ record.early_leave_minutes.to_i - early_leave_allowed, 0 ].max

        penalty = Attendance::PenaltyCalculator.calculate(
          record:                    record,
          daily_salary:              daily_rate,
          late_minutes_override:     effective_late,
          early_leave_minutes_override: effective_early
        )

        if penalty.late_penalty > 0
          items << item("late_penalty", -penalty.late_penalty, record, "Late arrival #{record.work_date}",
                        original_minutes: record.late_minutes.to_i, permission_minutes: late_allowed)
        end

        if penalty.early_leave_penalty > 0
          items << item("early_leave_penalty", -penalty.early_leave_penalty, record, "Early leave #{record.work_date}",
                        original_minutes: record.early_leave_minutes.to_i, permission_minutes: early_leave_allowed)
        end

        overtime = Salary::OvertimeCalculator.calculate(
          record:        record,
          daily_rate:    daily_rate,
          multiplier:    overtime_multiplier,
          grace_minutes: @business.overtime_grace_minutes.to_i
        )
        items << item("overtime", overtime.overtime_pay, record, "Overtime #{record.work_date}") if overtime.overtime_pay > 0

        items
      end
    end

    def absence_line_items(profile, days_worked, daily_rate)
      return [] unless profile.monthly?
      # Employees without an active shift assignment are not subject to absence tracking.
      return [] unless shift_assigned?

      absent_days = @period.working_days - days_worked
      return [] unless absent_days > 0

      amount = (absent_days * daily_rate).round(2)
      [ item("manual_adjustment", -amount, nil, "Absence deduction (#{absent_days} day(s))") ]
    end

    def shift_assigned?
      ShiftAssignment.active_on(@period.period_start).where(user: @user).exists?
    end

    def adjustment_line_items
      # Query by business + period month/year — independent of whether a PayrollPeriod record exists.
      PayrollAdjustment
        .where(
          business:     @business,
          period_month: @period.period_month,
          period_year:  @period.period_year,
          user:         @user,
          review_status: "approved"
        )
        .filter_map do |adj|
          type = adj.line_item_type
          # Skip if the resolved type is not a recognised PayrollLineItem type.
          # This guards against DB rows that predate a migration or contain
          # data-entry errors — they are skipped rather than crashing regeneration.
          next unless PayrollLineItem::ITEM_TYPES.include?(type)

          {
            item_type:     type,
            amount:        adj.signed_amount,
            description:   adj.reason,
            source_type:   "PayrollAdjustment",
            source_id:     adj.id,
            review_status: "approved",
            already_paid:  adj.already_paid?
          }
        end
    end

    def base(profile, daily_rate, days_worked)
      profile.monthly? ? profile.base_amount.to_f : (daily_rate * days_worked).round(2)
    end

    def sum_negatives(items)
      items.select { |i| i[:amount] < 0 }.sum { |i| i[:amount].abs }
    end

    def sum_positives(items)
      items.select { |i| i[:amount] > 0 }.sum { |i| i[:amount] }
    end

    def item(type, amount, source = nil, description = "", extras = {})
      {
        item_type:     type,
        amount:        amount.to_f.round(2),
        description:   description,
        source_type:   source&.class&.name,
        source_id:     source&.id,
        review_status: PayrollLineItem::REVIEW_REQUIRED_TYPES.include?(type) ? "pending_review" : "approved"
      }.merge(extras)
    end
  end
end
