module Payroll
  # Builds one PayrollEntry (+ its line items) for a single user in a payroll period.
  # Called once per user by PeriodGenerator. Returns nil if the user has no salary profile.
  class EntryCalculator
    # entry: an existing PayrollEntry to update in place (keeps its id stable)
    # instead of creating a new one. Used by EntryRecalculator so a single
    # attendance-triggered recalculation doesn't churn the entry's identity.
    def self.call(period:, user:, business:, entry: nil)
      new(period: period, user: user, business: business, entry: entry).call
    end

    # ── Shared calculation inputs ───────────────────────────────────────────
    # Also used by Payroll::OvertimeRecalculator so a day's overtime is always
    # priced exactly as a full payroll calculation would price it.

    # Salary is date-aware: every day of the period is priced with the profile
    # in force on THAT day (Salary::ProfileTimeline), so a salary change partway
    # through the month applies from its effective date — never the whole month
    # at one rate, never a profile before its effective_from.
    def self.timeline_for(user)
      Salary::ProfileTimeline.for(user)
    end

    # The profile and daily rate in force on one work day; nil before the
    # employee's first profile takes effect (that day earns and costs nothing).
    DayRate = Struct.new(:profile, :daily_rate, keyword_init: true) do
      def overtime_multiplier = profile.overtime_multiplier
    end

    def self.day_rate_for(timeline:, date:, business:)
      profile = timeline.profile_on(date)
      return nil unless profile

      DayRate.new(profile: profile, daily_rate: Salary::DailyRateCalculator.rate_for(profile, business))
    end

    # The attendance payroll reads for the period (only complete days pay).
    def self.attendance_records_for(user:, period:)
      AttendanceRecord
        .active
        .includes(shift_assignment: [ :rule_profile, { shift: :penalty_rules } ])
        .where(user: user)
        .for_period(period.period_start, period.period_end)
    end

    # One day's overtime under the business's CURRENT overtime threshold.
    def self.overtime_for(record:, daily_rate:, multiplier:, business:)
      Salary::OvertimeCalculator.calculate(
        record:        record,
        daily_rate:    daily_rate,
        multiplier:    multiplier,
        grace_minutes: business.overtime_grace_minutes.to_i,
        rule_profile:  record.shift_assignment&.rule_profile
      )
    end

    def initialize(period:, user:, business:, entry: nil)
      @period         = period
      @user           = user
      @business       = business
      @existing_entry = entry
      @calculated_overtime_minutes = 0
    end

    def call
      # The stretches of the period each salary profile covers (see
      # .timeline_for). No segment → no profile in force at any point of the
      # period (none at all, or the first only starts after it) → no entry.
      @timeline = self.class.timeline_for(@user)
      @segments = @timeline.segments(@period.period_start, @period.period_end)
      return nil if @segments.empty?

      # The employee is only active from their first effective_from onward. Base
      # salary, working days and absences are all scoped to that in-period window so
      # a mid-month hire is neither paid for nor penalised for days before they start.
      effective_start        = @segments.first.starts_on
      effective_working_days = @effective_working_days = working_days_for(effective_start)

      # The entry's salary_type is the type in force on the period's last day;
      # each stretch is still priced under its own profile and type.
      type_profile = @segments.last.profile

      records   = load_records
      insurance = resolve_insurance_snapshot

      # Only COMPLETE attendance days are payable. Incomplete/single-punch records
      # (check-in without check-out) remain visible in attendance reports but never
      # count toward worked days, payable days, or basic salary.
      days_worked        = records.count(&:complete?)
      line_items         = attendance_line_items(records)
      line_items        += absence_line_items(records)
      line_items        += insurance_line_items(insurance)
      advance_result     = AdvanceDeductor.call(user: @user, period: @period)
      obligation_result  = ObligationDeductor.call(user: @user, period: @period)
      adj_items          = adjustment_line_items

      basic                = BasicSalaryCalculator.call(period: @period, segments: @segments, records: records,
                                                        business: @business, working_days: effective_working_days)
      base_salary          = basic.amount.to_f
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
        attrs = {
          user:                 @user,
          salary_type:          type_profile.salary_type,
          base_salary:          basic.amount,
          # How base_salary was built, one portion per salary profile — replaced
          # on every recalculation; frozen with the entry once the period locks.
          salary_breakdown:     basic.breakdown,
          working_days:         effective_working_days,
          days_worked:          days_worked,
          total_deductions:     total_deductions.round(2),
          total_overtime:       total_overtime.round(2),
          # Pristine system overtime snapshot. At generation payable == calculated;
          # an override (if any) is re-applied afterwards by Payroll::Regenerator
          # or Payroll::EntryRecalculator, so any prior override is cleared here.
          calculated_overtime_minutes: @calculated_overtime_minutes,
          calculated_overtime_pay:     total_overtime.round(2),
          overtime_override_mode:     nil,
          approved_overtime_minutes:  nil,
          approved_overtime_pay:      nil,
          overtime_override_reason:   nil,
          overtime_overridden_by_id:  nil,
          overtime_overridden_at:     nil,
          overtime_override_stale:    false,
          total_bonuses:        total_bonuses.round(2),
          already_paid_total:   already_paid_total.round(2),
          advances_deducted:    advances_deducted.round(2),
          obligations_deducted: obligations_deducted.round(2),
          insured:                     insurance[:insured],
          employee_insurance_amount:   insurance[:employee_amount].round(2),
          employer_insurance_amount:   insurance[:employer_amount].round(2),
          insurance_number:            insurance[:insurance_number],
          net_salary:           net_salary.round(2),
          status:               "draft",
          notes:                nil
        }

        entry = if @existing_entry
          @existing_entry.payroll_line_items.destroy_all
          @existing_entry.update!(attrs)
          @existing_entry
        else
          # A brand-new entry has never been reviewed — start flagged so the
          # reviewer sees it, distinct from the dirty-tracking flip on
          # subsequent recalculations (see PayrollEntry#mark_needs_review!).
          @period.payroll_entries.create!(attrs.merge(needs_review: true))
        end

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

    # Insurance values are "live" (re-read from EmployeeInsuranceProfile on every
    # recalculation) up until the period's first finalize — matching every other
    # field (attendance, obligations, bonuses). But unlike those fields, once a
    # period has EVER been finalized, its insurance snapshot must stay frozen
    # for good, even if the period is later reopened and recalculated for an
    # unrelated reason: Payroll::EntryRecalculator runs on any !locked? period
    # (draft, under_review, branch_review_completed — including a reopened
    # finalized period, since Payroll::Reopener only ever returns a period to
    # branch_review_completed, never draft), triggered by attendance edits or
    # obligation changes that have nothing to do with insurance. Without this
    # guard, an unrelated attendance fix during a reopen would silently
    # re-derive insurance from whatever the profile says *today*, breaking the
    # "frozen after finalization" guarantee the feature depends on.
    #
    # period_ever_finalized? is the only reliable signal: PayrollPeriod#status
    # itself gets reset to branch_review_completed on reopen (see Reopener), so
    # status alone can't distinguish "never finalized" from "reopened".
    def resolve_insurance_snapshot
      profile = @user.employee_insurance_profile

      if @existing_entry && period_ever_finalized?
        {
          insured:          @existing_entry.insured?,
          employee_amount:  @existing_entry.employee_insurance_amount.to_f,
          employer_amount:  @existing_entry.employer_insurance_amount.to_f,
          insurance_number: @existing_entry.insurance_number,
          source:           @existing_entry.insured? ? profile : nil
        }
      else
        insured = profile&.covers_period?(@period.period_start, @period.period_end) || false
        {
          insured:          insured,
          employee_amount:  insured ? profile.employee_contribution_amount.to_f : 0.0,
          employer_amount:  insured ? profile.employer_contribution_amount.to_f : 0.0,
          insurance_number: insured ? profile.insurance_number : nil,
          source:           insured ? profile : nil
        }
      end
    end

    def period_ever_finalized?
      @period.payroll_audit_logs.exists?(action_type: "finalized")
    end

    def insurance_line_items(insurance)
      return [] unless insurance[:insured]

      [ item("insurance_deduction", -insurance[:employee_amount], insurance[:source], "Social insurance contribution") ]
    end

    def load_records
      self.class.attendance_records_for(user: @user, period: @period)
    end

    # Each day's penalties and overtime are priced with the profile in force on
    # that day (rate and overtime multiplier). A day before the first profile
    # takes effect has no salary to price against and produces no items.
    def attendance_line_items(records)
      records.flat_map do |record|
        next [] unless record.complete?

        day = self.class.day_rate_for(timeline: @timeline, date: record.work_date, business: @business)
        next [] unless day

        daily_rate = day.daily_rate
        items = []

        # Partial permission reduction: approved late/early-leave requests reduce the
        # penalised minutes proportionally rather than waiving the penalty entirely.
        late_allowed        = EmployeeRequest.approved_minutes(user: @user, date: record.work_date, type: "late_permission")
        early_leave_allowed = EmployeeRequest.approved_minutes(user: @user, date: record.work_date, type: "early_leave")
        effective_late      = [ record.late_minutes.to_i - late_allowed, 0 ].max
        effective_early     = [ record.early_leave_minutes.to_i - early_leave_allowed, 0 ].max

        penalty = Attendance::PenaltyCalculator.calculate(
          record:                       record,
          daily_salary:                 daily_rate,
          late_minutes_override:        effective_late,
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

        overtime = self.class.overtime_for(record: record, daily_rate: daily_rate,
                                           multiplier: day.overtime_multiplier, business: @business)
        if overtime.overtime_pay > 0
          items << item("overtime", overtime.overtime_pay, record, "Overtime #{record.work_date}")
          @calculated_overtime_minutes += overtime.overtime_minutes.to_i
        end

        items
      end
    end

    # Absence applies to the monthly-salaried part of the period only: its
    # working days less the complete days worked within it. Absent days carry
    # no date, so they are priced at the calendar-day-weighted average of the
    # monthly profiles in force during the period, over working_days_per_month
    # (with one monthly profile: exactly that profile's daily rate).
    def absence_line_items(records)
      monthly = monthly_segment_indexes
      return [] if monthly.empty?
      # Employees without an active shift assignment are not subject to absence tracking.
      return [] unless shift_assigned?(@segments[monthly.first].starts_on)

      monthly_working_days = monthly_part_working_days(monthly.sum { |i| @segments[i].days })
      monthly_days_worked  = monthly.sum { |i| complete_days_in(records, @segments[i]) }
      absent_days = monthly_working_days - monthly_days_worked
      return [] unless absent_days > 0

      amount = (absent_days * weighted_monthly_daily_rate(monthly)).round(2)
      [ item("manual_adjustment", -amount, nil, "Absence deduction (#{absent_days} day(s))") ]
    end

    # Working days of the monthly-salaried part, under the same proration rule
    # as its pay (Payroll::BasicSalaryCalculator): a mid-period starter's part
    # is its calendar share of the starter's working days (all of them when the
    # whole window is monthly — the established starter rule); otherwise its
    # calendar share of the period's working days.
    def monthly_part_working_days(monthly_days)
      salary_start = @segments.first.starts_on
      return prorated_working_days(monthly_days) unless salary_start > @period.period_start

      window_days = (@period.period_end - salary_start).to_i + 1
      return @effective_working_days if monthly_days >= window_days

      [ (@effective_working_days * monthly_days.to_f / window_days).round, 1 ].max
    end

    def monthly_segment_indexes
      @segments.each_index.select { |i| @segments[i].profile.monthly? }
    end

    def weighted_monthly_daily_rate(indexes)
      segments = indexes.map { |i| @segments[i] }
      weighted_base = segments.sum { |s| s.profile.base_amount.to_f * s.days } / segments.sum(&:days)
      (weighted_base / @business.working_days_per_month).round(4)
    end

    def complete_days_in(records, segment)
      records.count { |r| r.complete? && segment.cover?(r.work_date) }
    end

    # Absence is judged against the employee's active window: an assignment that
    # starts mid-month is "active" on the employee's effective_start, not on day 1.
    def shift_assigned?(on_date)
      ShiftAssignment.active_on(on_date).where(user: @user).exists?
    end

    # Working days the employee is actually active for within the period. Full-period
    # employees keep the period's standard working_days; mid-period starters get a
    # calendar-prorated slice (always at least one day if active at all).
    def working_days_for(effective_start)
      prorated_working_days((@period.period_end - effective_start).to_i + 1)
    end

    # The period's working days prorated to `calendar_days` of it (the whole
    # period keeps the standard working_days; any part at least one day).
    def prorated_working_days(calendar_days)
      total_days = (@period.period_end - @period.period_start).to_i + 1
      return @period.working_days if calendar_days >= total_days

      [ (@period.working_days * calendar_days.to_f / total_days).round, 1 ].max
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
