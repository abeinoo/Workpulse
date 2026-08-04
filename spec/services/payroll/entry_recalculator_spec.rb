require "rails_helper"

# Freeze time at July 15, 2026 so "last month" is always June 2026 (22 weekdays).
# Key figures used throughout:
#   salary_profile : SAR 8 800 / month (monthly)
#   daily_rate     : 8 800 / 22 = SAR 400
#   shift          : fixed-time 09:00–17:00 (480 min)
#   OT (60 min)    : (400/8) * 1.0 * 1.5 = SAR 75
#   late penalty   : 25 % of daily = SAR 100 (threshold 15 min, via penalty_rule)
#   early penalty  : same rule on early_leave
#   absence        : absent_days * 400 (monthly employee only)
RSpec.describe Payroll::EntryRecalculator do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 22, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:actor)    { create(:user, :accountant, business: business) }

  let(:shift) do
    create(:shift, :fixed_time, business: business,
           start_time: Time.zone.parse("09:00"),
           end_time:   Time.zone.parse("17:00"),
           overtime_rate_multiplier: 1.5)
  end

  let!(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift,
           effective_from: 6.months.ago.to_date)
  end

  let(:period) do
    create(:payroll_period, business: business,
           period_year: 2026, period_month: 6, working_days: 22)
  end

  let(:period_start) { period.period_start }  # 2026-06-01 (Monday)
  let(:period_end)   { period.period_end }    # 2026-06-30

  let!(:salary_profile) do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0,
           effective_from: 6.months.ago.to_date)
  end

  # Helpers ──────────────────────────────────────────────────────────────────

  def create_record(date, worked:, late: 0, early_leave: 0, status: "present")
    create(:attendance_record,
           user:                employee,
           branch:              branch,
           shift_assignment:    assignment,
           date:                date,
           work_date:           date,
           check_in_at:         Time.zone.local(date.year, date.month, date.day, 9, 0) + late.minutes,
           check_out_at:        Time.zone.local(date.year, date.month, date.day, 17, 0) - early_leave.minutes,
           worked_minutes:      worked,
           late_minutes:        late,
           early_leave_minutes: early_leave,
           status:              status)
  end

  def build_initial_entry
    Payroll::EntryCalculator.call(period: period, user: employee, business: business)
  end

  def current_entry
    period.payroll_entries.find_by(user: employee)
  end

  def run
    described_class.call(user: employee, period: period, triggered_by: actor)
  end

  # ── Period guards ──────────────────────────────────────────────────────────

  describe "locked period guards" do
    shared_examples "does not recalculate" do |status_label|
      it "returns ok: true without touching the entry" do
        initial = create(:payroll_entry, payroll_period: period, user: employee,
                         base_salary: 5_000.0, net_salary: 5_000.0, working_days: 22, days_worked: 22)
        result  = run
        expect(result.ok?).to be true
        expect(result.entry).to be_nil
        expect(initial.reload.net_salary).to eq(5_000.0)
      end

      it "does not destroy or create any PayrollEntry" do
        create(:payroll_entry, payroll_period: period, user: employee,
               base_salary: 5_000.0, net_salary: 5_000.0, working_days: 22, days_worked: 22)
        expect { run }.not_to change(PayrollEntry, :count)
      end
    end

    context "when the period is finalized" do
      before { period.update_column(:status, "finalized") }
      include_examples "does not recalculate", "finalized"
    end

    context "when the period is paid" do
      before { period.update_column(:status, "paid") }
      include_examples "does not recalculate", "paid"
    end
  end

  # ── Period state coverage ─────────────────────────────────────────────────

  describe "editable period states" do
    before { create_record(Date.new(2026, 6, 2), worked: 480) }

    context "draft" do
      it "succeeds and returns an entry" do
        result = run
        expect(result.ok?).to be true
        expect(result.entry).to be_a(PayrollEntry)
      end
    end

    context "under_review" do
      before { period.update_column(:status, "under_review") }

      it "succeeds" do
        expect(run.ok?).to be true
      end

      it "recalculates the entry in place, keeping its id stable" do
        initial = build_initial_entry
        expect(initial.days_worked).to eq(1)

        create_record(Date.new(2026, 6, 3), worked: 480)
        run

        expect(current_entry.id).to eq(initial.id)
        expect(current_entry.days_worked).to eq(2)
      end

      it "does not change the period's status" do
        build_initial_entry
        run
        expect(period.reload.status).to eq("under_review")
      end
    end

    context "branch_review_completed" do
      before { period.update_column(:status, "branch_review_completed") }

      it "succeeds and updates the entry in place, keeping its id stable" do
        initial = build_initial_entry
        create_record(Date.new(2026, 6, 3), worked: 480)
        run

        expect(current_entry.id).to eq(initial.id)
        expect(run.ok?).to be true
      end

      it "does not change the period's status" do
        build_initial_entry
        run
        expect(period.reload.status).to eq("branch_review_completed")
      end
    end
  end

  # ── No salary profile ─────────────────────────────────────────────────────

  describe "when the employee has no salary profile" do
    before { salary_profile.destroy! }

    it "returns ok: true with a nil entry" do
      result = run
      expect(result.ok?).to be true
      expect(result.entry).to be_nil
    end

    it "does not create a PayrollEntry" do
      expect { run }.not_to change(PayrollEntry, :count)
    end
  end

  # ── Working days ──────────────────────────────────────────────────────────

  describe "working days recalculation" do
    # June 2026 has exactly 22 weekdays and only 5 Mondays, so use full weekday list.
    let(:weekdays) { (period_start..period_end).reject { |d| d.saturday? || d.sunday? } }

    context "when attendance records are added between calculations" do
      before do
        weekdays.first(5).each { |d| create_record(d, worked: 480) }
        build_initial_entry
        expect(current_entry.days_worked).to eq(5)
      end

      it "increases days_worked to reflect the new records" do
        weekdays[5..7].each { |d| create_record(d, worked: 480) }
        run
        expect(current_entry.days_worked).to eq(8)
      end

      it "recalculates net_salary upward (fewer absent days)" do
        initial_net = current_entry.net_salary
        weekdays[5..7].each { |d| create_record(d, worked: 480) }
        run
        expect(current_entry.net_salary).to be > initial_net
      end
    end

    context "when a complete record is corrected to incomplete" do
      let(:target_day) { weekdays.first }

      before do
        weekdays.first(5).each { |d| create_record(d, worked: 480) }
        build_initial_entry
        expect(current_entry.days_worked).to eq(5)

        AttendanceRecord.find_by(user: employee, work_date: target_day)
                        .update_columns(check_out_at: nil, worked_minutes: nil, status: "incomplete")
      end

      it "decreases days_worked by one" do
        run
        expect(current_entry.days_worked).to eq(4)
      end

      it "adds an absence deduction for the now-incomplete day" do
        initial_deductions = current_entry.total_deductions
        run
        expect(current_entry.total_deductions).to be > initial_deductions
      end
    end
  end

  # ── Late penalty ──────────────────────────────────────────────────────────

  describe "late penalty recalculation" do
    let!(:late_rule) do
      create(:penalty_rule, shift: shift, rule_type: "late_arrival",
             deduction_type: "percentage_of_daily", threshold_minutes: 15, deduction_value: 25)
    end

    # Fill all 22 working days so absence deductions do not interfere with
    # penalty assertions.  One sentinel day is manipulated per context.
    let(:all_days) { (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(22) }
    let(:test_day) { Date.new(2026, 6, 1) }

    context "when late minutes are added (attendance was corrected to show lateness)" do
      before do
        all_days.each { |d| create_record(d, worked: 480) }
        build_initial_entry
        expect(current_entry.total_deductions).to eq(0.0)

        AttendanceRecord.find_by(user: employee, work_date: test_day)
                        .update_columns(late_minutes: 60, status: "late")
      end

      it "adds a late_penalty line item" do
        run
        expect(current_entry.payroll_line_items.where(item_type: "late_penalty").count).to eq(1)
      end

      it "deducts 25 % of daily rate (SAR 100) for the penalty" do
        run
        penalty = current_entry.payroll_line_items.find_by(item_type: "late_penalty")
        expect(penalty.amount).to eq(-100.0)
      end

      it "sets total_deductions to 100 (penalty only, no absences)" do
        run
        expect(current_entry.total_deductions).to eq(100.0)
      end

      it "reduces net_salary by SAR 100" do
        run
        expect(current_entry.net_salary).to eq(8_700.0)
      end
    end

    context "when late minutes are removed (attendance corrected to on-time)" do
      before do
        all_days.each do |d|
          d == test_day ? create_record(d, worked: 480, late: 60, status: "late")
                        : create_record(d, worked: 480)
        end
        build_initial_entry
        expect(current_entry.payroll_line_items.where(item_type: "late_penalty").count).to eq(1)

        AttendanceRecord.find_by(user: employee, work_date: test_day)
                        .update_columns(late_minutes: 0, status: "present")
      end

      it "removes the late_penalty line item" do
        run
        expect(current_entry.payroll_line_items.where(item_type: "late_penalty")).to be_empty
      end

      it "reduces total_deductions to zero" do
        run
        expect(current_entry.total_deductions).to eq(0.0)
      end

      it "restores net_salary to base_salary" do
        run
        expect(current_entry.net_salary).to eq(8_800.0)
      end
    end
  end

  # ── Early leave penalty ───────────────────────────────────────────────────

  describe "early leave penalty recalculation" do
    let!(:early_rule) do
      create(:penalty_rule, shift: shift, rule_type: "early_leave",
             deduction_type: "percentage_of_daily", threshold_minutes: 15, deduction_value: 25)
    end

    let(:all_days) { (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(22) }
    let(:test_day) { Date.new(2026, 6, 2) }

    context "when early leave is added" do
      before do
        all_days.each { |d| create_record(d, worked: 480) }
        build_initial_entry
        expect(current_entry.total_deductions).to eq(0.0)

        AttendanceRecord.find_by(user: employee, work_date: test_day)
                        .update_columns(early_leave_minutes: 60, status: "early_leave",
                                        check_out_at: Time.zone.local(2026, 6, 2, 16, 0),
                                        worked_minutes: 420)
      end

      it "adds an early_leave_penalty line item" do
        run
        expect(current_entry.payroll_line_items.where(item_type: "early_leave_penalty").count).to eq(1)
      end

      it "deducts 25 % of daily rate (SAR 100) for the early leave" do
        run
        penalty = current_entry.payroll_line_items.find_by(item_type: "early_leave_penalty")
        expect(penalty.amount).to eq(-100.0)
      end

      it "sets total_deductions to 100" do
        run
        expect(current_entry.total_deductions).to eq(100.0)
      end
    end

    context "when early leave is removed (attendance corrected)" do
      before do
        all_days.each do |d|
          d == test_day ? create_record(d, worked: 420, early_leave: 60, status: "early_leave")
                        : create_record(d, worked: 480)
        end
        build_initial_entry
        expect(current_entry.payroll_line_items.where(item_type: "early_leave_penalty").count).to eq(1)

        AttendanceRecord.find_by(user: employee, work_date: test_day)
                        .update_columns(early_leave_minutes: 0, status: "present",
                                        check_out_at: Time.zone.local(2026, 6, 2, 17, 0),
                                        worked_minutes: 480)
      end

      it "removes the early_leave_penalty line item" do
        run
        expect(current_entry.payroll_line_items.where(item_type: "early_leave_penalty")).to be_empty
      end

      it "reduces total_deductions to zero" do
        run
        expect(current_entry.total_deductions).to eq(0.0)
      end

      it "restores net_salary to base_salary" do
        run
        expect(current_entry.net_salary).to eq(8_800.0)
      end
    end
  end

  # ── Overtime changes ──────────────────────────────────────────────────────

  describe "overtime recalculation" do
    let(:test_day) { Date.new(2026, 6, 1) }

    context "when overtime is added" do
      before do
        create_record(test_day, worked: 480)
        build_initial_entry
        expect(current_entry.payroll_line_items.where(item_type: "overtime")).to be_empty
        expect(current_entry.total_overtime).to eq(0.0)

        # Attendance corrected: employee stayed 60 min longer
        AttendanceRecord.find_by(user: employee, work_date: test_day)
                        .update_columns(worked_minutes: 540,
                                        overtime_minutes: 60,
                                        check_out_at: Time.zone.local(2026, 6, 1, 18, 0))
      end

      it "adds an overtime line item" do
        run
        expect(current_entry.payroll_line_items.where(item_type: "overtime").count).to eq(1)
      end

      it "increases total_overtime above zero" do
        run
        expect(current_entry.total_overtime).to be > 0
      end

      it "snapshots calculated_overtime_minutes on the entry" do
        run
        expect(current_entry.calculated_overtime_minutes).to be > 0
      end

      it "increases net_salary by the overtime pay" do
        initial_net = current_entry.net_salary
        run
        expect(current_entry.net_salary).to be > initial_net
      end
    end

    context "when overtime is removed (check-out time corrected)" do
      before do
        rec = create_record(test_day, worked: 540)
        rec.update_columns(overtime_minutes: 60,
                           check_out_at: Time.zone.local(2026, 6, 1, 18, 0))
        build_initial_entry
        expect(current_entry.total_overtime).to be > 0

        # Correction: only worked 8 h
        AttendanceRecord.find_by(user: employee, work_date: test_day)
                        .update_columns(worked_minutes: 480,
                                        overtime_minutes: 0,
                                        check_out_at: Time.zone.local(2026, 6, 1, 17, 0))
      end

      it "removes the overtime line item" do
        run
        expect(current_entry.payroll_line_items.where(item_type: "overtime")).to be_empty
      end

      it "reduces total_overtime to zero" do
        run
        expect(current_entry.total_overtime).to eq(0.0)
      end

      it "reduces calculated_overtime_minutes to zero" do
        run
        expect(current_entry.calculated_overtime_minutes).to eq(0)
      end

      it "reduces net_salary accordingly" do
        initial_net = current_entry.net_salary
        run
        expect(current_entry.net_salary).to be < initial_net
      end
    end
  end

  # ── Absence changes ───────────────────────────────────────────────────────

  describe "absence deduction recalculation" do
    context "when no attendance records exist (full absence)" do
      it "creates a full-month absence deduction" do
        initial = build_initial_entry
        expect(initial.total_deductions).to eq(8_800.0)  # 22 * 400
        expect(initial.net_salary).to eq(0.0)
      end
    end

    context "when some attendance records are added (partial attendance)" do
      before { build_initial_entry }

      it "reduces the absence deduction proportionally" do
        # Use weekdays — June 2026 has only 5 Mondays so select(&:monday?).first(11) silently caps at 5.
        (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(11).each do |d|
          create_record(d, worked: 480)
        end
        run
        # 11 days present, 11 days absent → deduction = 11 * 400 = 4400, net = 4400
        expect(current_entry.net_salary).to be_within(0.01).of(4_400.0)
      end
    end

    context "when all 22 working days are attended" do
      before { build_initial_entry }

      it "removes the absence deduction entirely" do
        (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(22).each do |d|
          create_record(d, worked: 480)
        end
        run
        expect(current_entry.payroll_line_items.where(item_type: "manual_adjustment")).to be_empty
        expect(current_entry.net_salary).to eq(8_800.0)
      end
    end

    context "when a complete day is corrected to incomplete" do
      before do
        (period_start..period_end).select(&:monday?).first(10).each { |d| create_record(d, worked: 480) }
        build_initial_entry
        # Make one record incomplete
        day = period_start.next_occurring(:monday)
        AttendanceRecord.find_by(user: employee, work_date: day)
                        .update_columns(check_out_at: nil, worked_minutes: nil, status: "incomplete")
      end

      it "increases the absence deduction (one more absent day)" do
        initial_deductions = current_entry.total_deductions
        run
        expect(current_entry.total_deductions).to be > initial_deductions
      end

      it "decreases net_salary" do
        initial_net = current_entry.net_salary
        run
        expect(current_entry.net_salary).to be < initial_net
      end
    end
  end

  # ── Overtime override preservation ───────────────────────────────────────

  describe "overtime override preservation" do
    let(:ot_day) { Date.new(2026, 6, 1) }

    def apply_ot_override(entry, value:, reason:)
      Payroll::OvertimeOverrider.call(entry: entry, mode: "amount",
                                      value: value, reason: reason, actor: actor)
    end

    before do
      rec = create_record(ot_day, worked: 540)
      rec.update_columns(overtime_minutes: 60,
                         check_out_at: Time.zone.local(2026, 6, 1, 18, 0))
      initial = build_initial_entry
      # calculated_overtime_pay = 75; override to 50
      apply_ot_override(initial, value: 50, reason: "Capped by policy")
    end

    context "when the calculated overtime does not change" do
      it "preserves the override" do
        run
        expect(current_entry.overtime_overridden?).to be true
        expect(current_entry.overtime_override_mode).to eq("amount")
        expect(current_entry.overtime_override_reason).to eq("Capped by policy")
      end

      it "keeps payable overtime at the overridden value (SAR 50)" do
        run
        expect(current_entry.total_overtime).to eq(50.0)
      end

      it "does not flag the override as stale" do
        run
        expect(current_entry.overtime_override_stale).to be false
      end
    end

    context "when additional overtime is added (calculated OT increases)" do
      before do
        extra_day = Date.new(2026, 6, 2)
        r = create_record(extra_day, worked: 540)
        r.update_columns(overtime_minutes: 60,
                         check_out_at: Time.zone.local(2026, 6, 2, 18, 0))
      end

      it "preserves the override" do
        run
        expect(current_entry.overtime_overridden?).to be true
        expect(current_entry.overtime_override_reason).to eq("Capped by policy")
      end

      it "flags the override stale because calculated OT changed" do
        run
        expect(current_entry.overtime_override_stale).to be true
      end

      it "clamps the approved pay to the new calculated pay when the formula runs" do
        run
        # approved_pay (50) is still <= new_calc_pay (150), so it is preserved as-is
        expect(current_entry.total_overtime).to eq(50.0)
      end
    end

    context "when overtime is corrected away (worked hours reduced to 8 h)" do
      before do
        AttendanceRecord.find_by(user: employee, work_date: ot_day)
                        .update_columns(worked_minutes: 480,
                                        overtime_minutes: 0,
                                        check_out_at: Time.zone.local(2026, 6, 1, 17, 0))
      end

      it "drops the override entirely when calculated OT is zero" do
        run
        expect(current_entry.overtime_overridden?).to be false
      end

      it "sets total_overtime to zero" do
        run
        expect(current_entry.total_overtime).to eq(0.0)
      end
    end
  end

  # ── Deduction waiver preservation ─────────────────────────────────────────

  describe "manual deduction waiver preservation" do
    let!(:deduction_adj) do
      create(:payroll_adjustment, :manual_deduction, :approved,
             payroll_period: period, user: employee, business: business, amount: 300.0)
    end
    # Fill all 22 days so net_salary = base_salary once the waiver is applied.
    let(:all_days) { (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(22) }

    before do
      all_days.each { |d| create_record(d, worked: 480) }
      initial = build_initial_entry
      li = initial.payroll_line_items.find_by(item_type: "manual_deduction",
                                               source_id: deduction_adj.id)
      Payroll::DeductionWaiver.call(line_item: li, action: "waive",
                                    actor: actor, reason: "Excused by manager")
    end

    it "preserves the waiver on the recalculated entry" do
      run
      li = current_entry.payroll_line_items.find_by(item_type: "manual_deduction",
                                                     source_id: deduction_adj.id)
      expect(li).to be_present
      expect(li.deduction_waived).to be true
    end

    it "preserves the waiver reason" do
      run
      li = current_entry.payroll_line_items.find_by(item_type: "manual_deduction",
                                                     source_id: deduction_adj.id)
      expect(li.deduction_waiver_reason).to eq("Excused by manager")
    end

    it "does not deduct the waived amount from net_salary" do
      run
      # base 8800, attendance complete (no absence), deduction 300 but waived → net = 8800
      expect(current_entry.net_salary).to eq(8_800.0)
    end

    it "re-applies the waiver even when an attendance record is updated" do
      # Simulate a check-in correction on an already-present day (no new record needed).
      AttendanceRecord.find_by(user: employee, work_date: Date.new(2026, 6, 2))
                      .update_columns(check_in_at: Time.zone.local(2026, 6, 2, 9, 15))
      run
      li = current_entry.payroll_line_items.find_by(item_type: "manual_deduction",
                                                     source_id: deduction_adj.id)
      expect(li.deduction_waived).to be true
    end
  end

  # ── Attendance penalty waiver preservation ─────────────────────────────────

  describe "attendance penalty waiver preservation" do
    let!(:late_rule) do
      create(:penalty_rule, shift: shift, rule_type: "late_arrival",
             deduction_type: "percentage_of_daily", threshold_minutes: 15, deduction_value: 25)
    end
    let(:all_days) { (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(22) }
    let(:test_day) { Date.new(2026, 6, 1) }

    before do
      all_days.each do |d|
        d == test_day ? create_record(d, worked: 480, late: 60, status: "late")
                      : create_record(d, worked: 480)
      end
      initial = build_initial_entry
      li = initial.payroll_line_items.find_by(item_type: "late_penalty")
      Payroll::LineItemReviewer.call(line_item: li, action: "waive",
                                     reviewed_by: actor, notes: "Traffic accident, excused")
    end

    it "preserves the waived review_status on the recalculated entry" do
      run
      li = current_entry.payroll_line_items.find_by(item_type: "late_penalty")
      expect(li).to be_present
      expect(li.waived?).to be true
    end

    it "preserves the review notes and reviewer" do
      run
      li = current_entry.payroll_line_items.find_by(item_type: "late_penalty")
      expect(li.review_notes).to eq("Traffic accident, excused")
      expect(li.reviewed_by).to eq(actor)
    end

    it "does not deduct the waived penalty from net_salary" do
      run
      expect(current_entry.net_salary).to eq(8_800.0)
    end

    it "re-applies the waiver even when an unrelated attendance record is updated" do
      AttendanceRecord.find_by(user: employee, work_date: Date.new(2026, 6, 2))
                      .update_columns(check_in_at: Time.zone.local(2026, 6, 2, 9, 15))
      run
      li = current_entry.payroll_line_items.find_by(item_type: "late_penalty")
      expect(li.waived?).to be true
    end
  end

  # ── Obligation deduction balance accounting ────────────────────────────────

  describe "obligation deduction balance accounting" do
    let!(:obligation) do
      create(:employee_obligation,
             user:               employee,
             business:           business,
             created_by:         actor,
             start_month:        period.period_month,
             start_year:         period.period_year,
             total_amount:       3_000.0,
             remaining_amount:   3_000.0,
             installment_amount: 500.0,
             auto_deduct:        true)
    end

    before do
      create_record(Date.new(2026, 6, 1), worked: 480)
      build_initial_entry
      # EntryCalculator created one ObligationDeduction snapshot and decremented balance.
    end

    it "restores the balance before re-deducting (no double-deduction)" do
      obligation.reload
      expect(obligation.remaining_amount).to eq(2_500.0)  # decremented once

      create_record(Date.new(2026, 6, 2), worked: 480)
      run

      obligation.reload
      expect(obligation.remaining_amount).to eq(2_500.0)  # still decremented exactly once
    end

    it "maintains exactly one ObligationDeduction snapshot per period after recalculation" do
      create_record(Date.new(2026, 6, 2), worked: 480)
      run

      expect(ObligationDeduction.where(payroll_period: period).count).to eq(1)
    end

    it "includes the obligation deduction line item in the recalculated entry" do
      create_record(Date.new(2026, 6, 2), worked: 480)
      run

      expect(current_entry.payroll_line_items.where(item_type: "obligation_deduction").count).to eq(1)
    end
  end

  # ── needs_review flagging ──────────────────────────────────────────────────

  describe "needs_review flagging" do
    before { period.update_column(:status, "under_review") }

    it "flags a brand-new entry as needing review (never yet reviewed)" do
      create_record(Date.new(2026, 6, 1), worked: 480)
      initial = build_initial_entry
      expect(initial.needs_review?).to be true
    end

    it "re-flags a previously-reviewed entry when attendance changes actually change the payable result" do
      create_record(Date.new(2026, 6, 1), worked: 480)
      initial = build_initial_entry
      initial.update!(needs_review: false)

      create_record(Date.new(2026, 6, 2), worked: 480)
      run

      expect(current_entry.needs_review?).to be true
    end

    it "does not re-flag a reviewed entry when the recalculation changes nothing" do
      create_record(Date.new(2026, 6, 1), worked: 480)
      build_initial_entry.update!(needs_review: false)

      run

      expect(current_entry.needs_review?).to be false
    end

    it "never flags once the period is locked" do
      create_record(Date.new(2026, 6, 1), worked: 480)
      build_initial_entry.update!(needs_review: false)
      period.update_column(:status, "finalized")

      create_record(Date.new(2026, 6, 2), worked: 480)
      run

      expect(current_entry&.needs_review?).to be_falsey
    end
  end

  # ── recalculate_all_open_periods_for ───────────────────────────────────────

  describe ".recalculate_all_open_periods_for" do
    let(:other_period) do
      create(:payroll_period, business: business, period_year: 2026, period_month: 5, working_days: 22, status: "under_review")
    end
    let(:locked_period) do
      create(:payroll_period, business: business, period_year: 2026, period_month: 4, working_days: 22, status: "finalized")
    end

    before do
      create_record(Date.new(2026, 6, 1), worked: 480)
      build_initial_entry
      Payroll::EntryCalculator.call(period: other_period, user: employee, business: business)
      Payroll::EntryCalculator.call(period: locked_period, user: employee, business: business)
    end

    it "recalculates every non-locked period that already has an entry for the user" do
      other_entry = other_period.payroll_entries.find_by(user: employee)
      other_entry.update!(base_salary: 1.0)

      described_class.recalculate_all_open_periods_for(user: employee, triggered_by: actor)

      expect(other_entry.reload.base_salary).to eq(8_800.0)
    end

    it "does not touch entries in locked periods" do
      locked_entry = locked_period.payroll_entries.find_by(user: employee)
      locked_entry.update_column(:base_salary, 1.0)

      described_class.recalculate_all_open_periods_for(user: employee, triggered_by: actor)

      expect(locked_entry.reload.base_salary).to eq(1.0)
    end
  end
end
