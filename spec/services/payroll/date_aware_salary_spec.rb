require "rails_helper"

# Regression: payroll priced a whole month with the single salary profile in
# force on the period's first day (EntryCalculator.rate_calculator_for's anchor),
# so a raise effective on October 15 was ignored for October — reported as 14
# attendance days paid 14 × 461.54 = 6,461.56 instead of the new 500 from the
# 15th. Every day is now priced with the profile in force on THAT day
# (Salary::ProfileTimeline): basic pay, penalties, overtime and its multiplier,
# absence, the overtime recalculation and the permission apply/revert paths.
RSpec.describe "Date-aware salary in payroll" do
  around { |ex| travel_to(Time.zone.local(2026, 11, 10, 12, 0, 0)) { ex.run } }

  let(:business) do
    create(:business, working_days_per_month: 26, timezone: "UTC", overtime_grace_minutes: 30)
  end
  let(:branch) { create(:branch, business: business) }
  let(:user)   { create(:user, business: business) }
  let(:actor)  { create(:user, :accountant, business: business) }

  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"),
           end_time: Time.zone.parse("17:00"), overtime_rate_multiplier: 1.5)
  end
  let!(:assignment) do
    create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let!(:late_rule) do
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                          deduction_type: "percentage_of_daily", deduction_value: 50)
  end

  let(:october) { create(:payroll_period, business: business, period_year: 2026, period_month: 10, working_days: 26) }

  def daily(amount, from, multiplier: nil)
    create(:salary_profile, :daily, user: user, base_amount: amount, effective_from: from,
                                    overtime_multiplier: multiplier)
  end

  def monthly(amount, from)
    create(:salary_profile, :monthly, user: user, base_amount: amount, effective_from: from)
  end

  def oct(day) = Date.new(2026, 10, day)

  def work(date, late: 0, overtime: 0)
    create(:attendance_record, user: user, branch: branch, shift_assignment: assignment,
           date: date, work_date: date,
           check_in_at:  Time.zone.local(date.year, date.month, date.day, 9, 0) + late.minutes,
           check_out_at: Time.zone.local(date.year, date.month, date.day, 17, 0) + overtime.minutes,
           worked_minutes: 480 - late + overtime, late_minutes: late, early_leave_minutes: 0,
           status: late.positive? ? "late" : "present")
  end

  def calculate(period = october)
    Payroll::EntryCalculator.call(period: period, user: user.reload, business: business)
  end

  def line_for(entry, record, type)
    entry.payroll_line_items.find_by(source_type: "AttendanceRecord", source_id: record.id, item_type: type)
  end

  # Overtime pay for `minutes` at `daily_rate` on the 8-hour shift, multiplier `m`.
  def ot_pay(daily_rate, minutes, m = 1.5) = (daily_rate / 8.0 * m * minutes / 60.0)

  describe "Salary::ProfileTimeline" do
    it "resolves every day exactly as SalaryProfile.effective_for does, ties included" do
      daily(400, Date.new(2026, 9, 1))
      daily(450, oct(8))
      daily(455, oct(8)) # same day, entered later → wins the tie
      daily(500, oct(15))
      daily(600, Date.new(2026, 11, 1)) # future-dated

      timeline = Salary::ProfileTimeline.for(user.reload)
      (Date.new(2026, 8, 25)..Date.new(2026, 11, 5)).each do |date|
        expect(timeline.profile_on(date)).to eq(SalaryProfile.effective_for(user, date: date)), date.to_s
      end
    end

    it "splits a range into the stretches each profile covers, skipping days before the first" do
      first  = daily(500, oct(10))
      second = daily(550, oct(20))

      segments = Salary::ProfileTimeline.for(user.reload).segments(oct(1), oct(31))
      expect(segments.map { |s| [ s.profile, s.starts_on, s.ends_on ] })
        .to eq([ [ first, oct(10), oct(19) ], [ second, oct(20), oct(31) ] ])
    end
  end

  describe "Scenario A — salary increase during the period (daily)" do
    before do
      daily(461.54, Date.new(2026, 3, 1))
      daily(500, oct(15))
    end

    it "prices October 14 at 461.54 and October 15 and 16 at 500" do
      [ 14, 15, 16 ].each { |d| work(oct(d)) }

      expect(calculate.base_salary.to_f).to eq((461.54 + 500 + 500).round(2))
    end

    it "fixes the reported case: 14 days split 7 / 7 around the effective date" do
      [ 1, 4, 6, 7, 8, 11, 14, 15, 18, 20, 21, 25, 28, 29 ].each { |d| work(oct(d)) }

      entry = calculate
      expect(entry.days_worked).to eq(14)
      expect(entry.base_salary.to_f).to eq((7 * 461.54 + 7 * 500).round(2)) # 6,730.78, not 6,461.56
      expect(entry.salary_type).to eq("daily")
    end

    it "prices late penalties and overtime with each day's own rate" do
      late_before = work(oct(13), late: 60)
      late_after  = work(oct(16), late: 60)
      ot_before   = work(oct(14), overtime: 60)
      ot_after    = work(oct(15), overtime: 60)

      entry = calculate
      expect(line_for(entry, late_before, "late_penalty").amount.to_f).to eq(-(461.54 / 2).round(2))
      expect(line_for(entry, late_after, "late_penalty").amount.to_f).to eq(-250.0)
      expect(line_for(entry, ot_before, "overtime").amount.to_f).to be_within(0.01).of(ot_pay(461.54, 60))
      expect(line_for(entry, ot_after, "overtime").amount.to_f).to be_within(0.01).of(ot_pay(500, 60))
    end

    it "applies each profile's own overtime multiplier on its days" do
      SalaryProfile.where(user: user).delete_all
      daily(400, Date.new(2026, 3, 1), multiplier: 1.0)
      daily(400, oct(15), multiplier: 2.0)
      before_change = work(oct(14), overtime: 60)
      after_change  = work(oct(15), overtime: 60)

      entry = calculate
      expect(line_for(entry, before_change, "overtime").amount.to_f).to be_within(0.01).of(ot_pay(400, 60, 1.0))
      expect(line_for(entry, after_change, "overtime").amount.to_f).to be_within(0.01).of(ot_pay(400, 60, 2.0))
    end
  end

  describe "Scenario B — future-dated salary profile" do
    it "never prices October with the profile effective November 1" do
      daily(500, Date.new(2026, 3, 1))
      daily(600, Date.new(2026, 11, 1))
      [ 5, 20, 31 ].each { |d| work(oct(d)) }

      expect(calculate.base_salary.to_f).to eq(1_500.0)
    end

    it "creates no entry when the first profile only starts after the period" do
      daily(600, Date.new(2026, 11, 1))
      work(oct(20))

      expect(calculate).to be_nil
    end
  end

  describe "Scenario C — historical payroll" do
    it "prices a past month with the profiles in force then, not today's salary" do
      daily(400, Date.new(2026, 1, 1))
      daily(450, Date.new(2026, 3, 10))
      daily(700, Date.new(2026, 6, 1)) # today's salary
      march = create(:payroll_period, business: business, period_year: 2026, period_month: 3, working_days: 26)
      work(Date.new(2026, 3, 5))
      work(Date.new(2026, 3, 12))

      expect(calculate(march).base_salary.to_f).to eq(850.0)
    end
  end

  describe "Scenario D — several salary changes in one period" do
    it "prices each day with the profile in force on it" do
      daily(400, Date.new(2026, 9, 1))
      daily(450, oct(8))
      daily(500, oct(15))
      daily(550, oct(22))
      [ 7, 8, 14, 15, 21, 22, 31 ].each { |d| work(oct(d)) }

      expect(calculate.base_salary.to_f).to eq(400 + 450 + 450 + 500 + 500 + 550 + 550.0)
    end
  end

  describe "Scenario E — days before the first effective profile" do
    before { daily(500, oct(15)) }

    it "pays nothing for them and never borrows the later profile" do
      early = work(oct(10), late: 60, overtime: 120)
      work(oct(14))
      work(oct(15))
      work(oct(20))

      entry = calculate
      expect(entry.base_salary.to_f).to eq(1_000.0)
      expect(entry.days_worked).to eq(4) # attendance is still counted as recorded
      expect(entry.payroll_line_items.where(source_type: "AttendanceRecord", source_id: early.id)).to be_empty
    end
  end

  describe "monthly salary change during the period" do
    # October: 31 calendar days, 26 working days. 9,000 from Mar 1, 12,000 from
    # Oct 15 → Oct 1–14 (14 days) and Oct 15–31 (17 days), each at its exact
    # calendar fraction: 9000×14/31 + 12000×17/31 = 330000/31 = 10,645.1612…
    before do
      monthly(9_000, Date.new(2026, 3, 1))
      monthly(12_000, oct(15))
    end

    it "splits the base salary by exact calendar-day fractions around the effective date" do
      entry = calculate
      expect(entry.base_salary).to eq(BigDecimal("10645.16"))
      expect(entry.working_days).to eq(26)
      expect(entry.salary_type).to eq("monthly")
      expect(entry.salary_breakdown_portions.map { |p| p["amount"] }).to eq(%w[4064.52 6580.64])
    end

    it "prices absence at the calendar-day-weighted monthly rate over working_days_per_month" do
      (1..10).each { |d| work(oct(d)) }
      (15..24).each { |d| work(oct(d)) }

      weighted_rate = ((9_000 * 14 + 12_000 * 17) / 31.0 / 26).round(4)
      absence = calculate.payroll_line_items.find_by(item_type: "manual_adjustment")
      expect(absence.description).to eq("Absence deduction (6 day(s))")
      expect(absence.amount.to_f).to eq(-(6 * weighted_rate).round(2))
    end

    it "keeps the full monthly base when only the overtime multiplier changed" do
      SalaryProfile.where(user: user).delete_all
      monthly(9_000, Date.new(2026, 3, 1))
      create(:salary_profile, :monthly, user: user, base_amount: 9_000, effective_from: oct(15), overtime_multiplier: 2.0)

      expect(calculate.base_salary.to_f).to eq(9_000.0)
    end

    it "keeps a single full-month monthly profile at exactly its base amount" do
      SalaryProfile.where(user: user).delete_all
      monthly(9_000, Date.new(2026, 3, 1))

      expect(calculate.base_salary.to_f).to eq(9_000.0)
    end
  end

  describe "salary type change during the period" do
    it "monthly → daily: each part priced under its own type; salary_type is the last day's" do
      monthly(9_000, Date.new(2026, 3, 1))
      daily(500, oct(15))
      (1..10).each { |d| work(oct(d)) }  # 10 days in the monthly part (26×14/31 → 12 working days)
      (15..22).each { |d| work(oct(d)) } # 8 days in the daily part

      entry = calculate
      expect(entry.salary_type).to eq("daily")
      # 9000×14/31 = 4,064.516… + 8 × 500 = 8,064.516… → 8,064.52
      expect(entry.base_salary).to eq(BigDecimal("8064.52"))
      expect(entry.salary_breakdown_portions.map { |p| p.values_at("salary_type", "amount", "days_worked") })
        .to eq([ [ "monthly", "4064.52", 10 ], [ "daily", "4000.00", 8 ] ])
      absence = entry.payroll_line_items.find_by(item_type: "manual_adjustment")
      expect(absence.amount.to_f).to eq(-(2 * 346.1538).round(2)) # absence only on the monthly part
    end

    it "daily → monthly: salary_type monthly, days worked before the change paid daily" do
      daily(500, Date.new(2026, 3, 1))
      monthly(12_000, oct(15))
      (5..9).each { |d| work(oct(d)) }
      (15..31).each { |d| work(oct(d)) } # 17 days ≥ the monthly part's 14 working days

      entry = calculate
      expect(entry.salary_type).to eq("monthly")
      # 5 × 500 + 12000×17/31 = 2,500 + 6,580.645… = 9,080.645… → 9,080.65 (half up)
      expect(entry.base_salary).to eq(BigDecimal("9080.65"))
      expect(entry.payroll_line_items.where(item_type: "manual_adjustment")).to be_empty
    end

    it "daily → monthly with absence on the monthly part only" do
      daily(500, Date.new(2026, 3, 1))
      monthly(12_000, oct(15))
      (15..24).each { |d| work(oct(d)) } # 10 of the monthly part's 14 working days

      absence = calculate.payroll_line_items.find_by(item_type: "manual_adjustment")
      expect(absence.description).to eq("Absence deduction (4 day(s))")
      expect(absence.amount.to_f).to eq(-(4 * (12_000 / 26.0).round(4)).round(2))
    end
  end

  describe "late/early permission apply and revert" do
    before do
      daily(400, Date.new(2026, 3, 1))
      daily(500, oct(15))
      october.update!(status: "under_review")
    end

    let!(:late_day) { work(oct(20), late: 60) }

    def request
      @request ||= build(:employee_request, :late_permission, :approved, user: user,
                                                                         requested_for_date: oct(20), duration_minutes: 30)
                     .tap { |r| r.save!(validate: false) }
    end

    it "re-prices with the attendance day's rate (500), not the period start's (400)" do
      entry = calculate
      expect(line_for(entry, late_day, "late_penalty").amount.to_f).to eq(-250.0)

      Payroll::PermissionApplier.call(request)
      expect(line_for(entry, late_day, "late_penalty").amount.to_f).to eq(-250.0) # 30 min still over threshold

      expect(Payroll::PermissionReverter.call(request)).to eq(:reverted)
      expect(line_for(entry, late_day, "late_penalty").reload.amount.to_f).to eq(-250.0)
    end
  end

  describe "overtime recalculation after a salary change" do
    it "re-prices each overtime day with the profile in force on it" do
      daily(400, Date.new(2026, 3, 1))
      before_raise = work(oct(10), overtime: 60)
      after_raise  = work(oct(20), overtime: 60)
      calculate
      october.update!(status: "under_review")

      # The raise is entered without the automatic recalculation (as if it
      # landed after review began through a path that did not recalculate).
      daily(500, oct(15))

      service = Payroll::OvertimeRecalculator.new(period_id: october.id, actor: actor)
      expect(service.apply!(expected_digest: service.preview.preview.digest)).to be_ok

      entry = october.payroll_entries.find_by!(user: user)
      expect(line_for(entry, before_raise, "overtime").amount.to_f).to be_within(0.01).of(ot_pay(400, 60))
      expect(line_for(entry, after_raise, "overtime").amount.to_f).to be_within(0.01).of(ot_pay(500, 60))
    end
  end

  describe "Scenario F — existing payroll entries when a salary profile is added" do
    let(:september) { create(:payroll_period, business: business, period_year: 2026, period_month: 9, working_days: 26) }

    before do
      daily(400, Date.new(2026, 1, 1))
      work(Date.new(2026, 9, 20))
      work(oct(20))
    end

    def enter_raise!
      Salary::ProfileUpdater.call(user: user, actor: actor, source: "admin",
                                  params: { salary_type: "daily", base_amount: 500, currency: "EGP",
                                            effective_from: Date.new(2026, 9, 15) })
    end

    %w[finalized paid].each do |status|
      it "leaves a #{status} entry and its line items untouched" do
        entry = calculate(september)
        september.update!(status: status)
        before_entry = entry.reload.attributes
        before_items = entry.payroll_line_items.order(:id).map(&:attributes)

        expect(enter_raise!).to be_success

        expect(entry.reload.attributes).to eq(before_entry)
        expect(entry.payroll_line_items.order(:id).map(&:attributes)).to eq(before_items)
        expect(entry.base_salary.to_f).to eq(400.0)
        expect(entry.salary_breakdown["total"]).to eq("400.00")
      end
    end

    %w[draft under_review branch_review_completed].each do |status|
      it "recalculates a #{status} entry with the date-aware rate" do
        entry = calculate(october)
        october.update!(status: status)
        expect(entry.base_salary.to_f).to eq(400.0)

        enter_raise!

        expect(entry.reload.base_salary.to_f).to eq(500.0)
      end
    end
  end

  describe "persisted salary breakdown" do
    it "records one portion per profile with its reference, range, type, amounts and days" do
      first  = daily(461.54, Date.new(2026, 3, 1))
      second = daily(500, oct(15))
      [ 13, 14, 15, 16, 17 ].each { |d| work(oct(d)) }

      entry = calculate
      expect(entry.salary_breakdown).to include(
        "version" => 1, "rounding" => Payroll::BasicSalaryCalculator::ROUNDING,
        "period_start" => "2026-10-01", "period_end" => "2026-10-31", "period_calendar_days" => 31,
        "total" => "2423.08"
      )
      expect(entry.salary_breakdown_portions).to eq([
        { "salary_profile_id" => first.id, "salary_type" => "daily", "base_amount" => "461.54",
          "starts_on" => "2026-10-01", "ends_on" => "2026-10-14", "calendar_days" => 14,
          "days_worked" => 2, "amount" => "923.08" },
        { "salary_profile_id" => second.id, "salary_type" => "daily", "base_amount" => "500.00",
          "starts_on" => "2026-10-15", "ends_on" => "2026-10-31", "calendar_days" => 17,
          "days_worked" => 3, "amount" => "1500.00" }
      ])
      expect(entry.base_salary).to eq(BigDecimal("2423.08"))
      expect(entry).to be_split_salary
    end

    it "records a single portion for an unchanged salary (not split)" do
      monthly(9_000, Date.new(2026, 3, 1))

      entry = calculate
      expect(entry.salary_breakdown_portions.size).to eq(1)
      expect(entry.salary_breakdown["total"]).to eq("9000.00")
      expect(entry).not_to be_split_salary
    end

    it "is replaced, consistent with the new totals, when an editable entry is recalculated" do
      daily(400, Date.new(2026, 3, 1))
      work(oct(10))
      work(oct(20))
      entry = calculate
      october.update!(status: "under_review")
      expect(entry.salary_breakdown["total"]).to eq("800.00")

      Salary::ProfileUpdater.call(user: user, actor: actor, source: "admin",
                                  params: { salary_type: "daily", base_amount: 500, currency: "EGP", effective_from: oct(15) })

      entry.reload
      expect(entry.base_salary).to eq(BigDecimal("900.00"))
      expect(entry.salary_breakdown["total"]).to eq("900.00")
      expect(entry.salary_breakdown_portions.map { |p| p["amount"] }).to eq(%w[400.00 500.00])
    end

    it "is rebuilt with the entry when a draft period is regenerated" do
      daily(400, Date.new(2026, 3, 1))
      work(oct(20))
      october # the draft period PeriodGenerator regenerates
      Payroll::PeriodGenerator.call(business: business, year: 2026, month: 10, generated_by: actor)
      create(:salary_profile, :daily, user: user, base_amount: 500, effective_from: oct(15))

      Payroll::Regenerator.call(period: october.reload, regenerated_by: actor)

      entry = october.payroll_entries.find_by!(user: user)
      expect(entry.salary_breakdown_portions.map { |p| p["amount"] }).to eq(%w[0.00 500.00])
      expect(entry.base_salary).to eq(BigDecimal("500.00"))
    end
  end

  describe "rounding policy" do
    it "rounds the total once and apportions cents so the portions sum exactly to it" do
      # 1000 × 10/31 = 322.580…, 1000 × 10/31, 1000 × 11/31 = 354.838… — exact sum 1000.
      monthly(1_000, Date.new(2026, 3, 1))
      monthly(1_000, oct(11))
      monthly(1_000, oct(21))

      entry = calculate
      expect(entry.base_salary).to eq(BigDecimal("1000.00"))
      expect(entry.salary_breakdown_portions.map { |p| p["amount"] }).to eq(%w[322.58 322.58 354.84])
    end

    it "keeps cents consistent across many changes" do
      [ [ Date.new(2026, 3, 1), 7_777.77 ], [ oct(4), 8_123.45 ], [ oct(9), 9_001.01 ],
        [ oct(17), 6_543.21 ], [ oct(30), 12_345.67 ] ].each { |from, amount| monthly(amount, from) }

      entry = calculate
      exact = (7_777.77r * 3 + 8_123.45r * 5 + 9_001.01r * 8 + 6_543.21r * 13 + 12_345.67r * 2) / 31
      expect(entry.base_salary).to eq(BigDecimal((exact * 100).round(half: :up)) / 100)
      expect(entry.salary_breakdown_portions.sum { |p| BigDecimal(p["amount"]) }).to eq(entry.base_salary)
    end
  end

  describe "calendar boundaries" do
    def period_for(year, month) = create(:payroll_period, business: business, period_year: year, period_month: month, working_days: 26)

    it "uses 29 days for February in a leap year" do
      monthly(3_000, Date.new(2028, 1, 1))
      monthly(6_000, Date.new(2028, 2, 15))

      # 3000×14/29 + 6000×15/29 = 132000/29 = 4,551.724…
      expect(calculate(period_for(2028, 2)).base_salary).to eq(BigDecimal("4551.72"))
    end

    it "uses 28 days for February in a common year" do
      monthly(3_000, Date.new(2027, 1, 1))
      monthly(6_000, Date.new(2027, 2, 15))

      expect(calculate(period_for(2027, 2)).base_salary).to eq(BigDecimal("4500.00"))
    end

    it "a change effective on the period's first day prices the whole month with it" do
      monthly(9_000, Date.new(2026, 3, 1))
      monthly(12_000, oct(1))

      entry = calculate
      expect(entry.base_salary).to eq(BigDecimal("12000.00"))
      expect(entry).not_to be_split_salary
    end

    it "a change effective on the period's last day applies to that one day" do
      monthly(9_000, Date.new(2026, 3, 1))
      monthly(12_000, oct(31))

      # 9000×30/31 + 12000×1/31 = 282000/31 = 9,096.774…
      expect(calculate.base_salary).to eq(BigDecimal("9096.77"))
    end

    it "a change effective the day after the period never reaches it" do
      monthly(9_000, Date.new(2026, 3, 1))
      monthly(12_000, Date.new(2026, 11, 1))

      expect(calculate.base_salary).to eq(BigDecimal("9000.00"))
    end
  end

  # Two monthly proration rules, chosen explicitly per entry:
  #   - salaried since the period's first day → exact calendar-day fractions;
  #   - FIRST profile starts mid-period → the established starter rule,
  #     base / working_days_per_month × W, W = round(26 × window days / 31).
  # October 16 start: window Oct 16–31 = 16 days → W = round(13.42) = 13.
  describe "monthly proration rule per entry" do
    describe "case 1 — salaried before the period, salary changes within it" do
      it "uses exact calendar-day fractions" do
        monthly(9_000, Date.new(2026, 3, 1))
        monthly(12_000, oct(16))

        entry = calculate
        expect(entry.base_salary).to eq(BigDecimal("10548.39")) # 9000×15/31 + 12000×16/31 = 327000/31
        expect(entry.working_days).to eq(26)
        expect(entry.salary_breakdown).to include("proration" => "calendar_days")
        expect(entry.salary_breakdown).not_to have_key("starter_working_days")
      end
    end

    describe "case 2 — first profile starts mid-period (starter)" do
      before { monthly(9_000, oct(16)) }

      it "keeps the established starter proration (EGP 4,500, not 4,645.16)" do
        entry = calculate
        expect(entry.base_salary).to eq(BigDecimal("4500.00")) # 9000 / 26 × 13
        expect(entry.working_days).to eq(13)
        expect(entry.salary_breakdown).to include(
          "proration" => "starter_working_days", "salary_starts_on" => "2026-10-16",
          "salary_window_days" => 16, "starter_working_days" => 13, "working_days_per_month" => 26, "total" => "4500.00"
        )
      end

      it "deducts absence against the starter's working days at the profile's daily rate" do
        (16..25).each { |d| work(oct(d)) } # 10 of 13 working days

        absence = calculate.payroll_line_items.find_by(item_type: "manual_adjustment")
        expect(absence.description).to eq("Absence deduction (3 day(s))")
        expect(absence.amount.to_f).to eq(-(3 * (9_000 / 26.0).round(4)).round(2)) # −1,038.46, as before
      end

      it "neither pays nor offsets absence with attendance before salary eligibility" do
        work(oct(14))
        (16..28).each { |d| work(oct(d)) } # all 13 working days

        entry = calculate
        expect(entry.base_salary).to eq(BigDecimal("4500.00"))
        expect(entry.days_worked).to eq(14)
        expect(entry.payroll_line_items.where(item_type: "manual_adjustment")).to be_empty
      end

      it "matches the established rule (daily rate × starter working days) for every start day" do
        SalaryProfile.where(user: user).delete_all
        [ 9_000, 7_777.77, 12_345.67 ].each do |amount|
          (2..31).each do |day|
            october.payroll_entries.destroy_all
            SalaryProfile.where(user: user).delete_all
            profile = monthly(amount, oct(day))
            working_days = [ (26 * (32 - day) / 31.0).round, 1 ].max
            # The established rule (daily rate to 4 decimals × working days), in
            # exact decimals with the approved half-up rounding.
            daily_rate  = BigDecimal(Salary::DailyRateCalculator.rate_for(profile, business).to_s)
            established = (daily_rate * working_days).round(2, BigDecimal::ROUND_HALF_UP)

            expect(calculate.base_salary).to eq(established), "#{amount} from Oct #{day}"
          end
        end
      end

      it "rounds an exact half-cent tie up, where the old Float product fell just below it" do
        SalaryProfile.where(user: user).delete_all
        monthly(7_777.77, oct(4)) # 299.145 × 23 = 6,880.335 exactly (Float: 6,880.334999…)

        expect(calculate.base_salary).to eq(BigDecimal("6880.34"))
      end
    end

    describe "case 3 — starter whose salary changes again within the period" do
      it "shares the starter's working days between the profiles by calendar days" do
        monthly(9_000, oct(16))
        monthly(12_000, oct(24)) # window 16 days: Oct 16–23 (8) and Oct 24–31 (8)

        entry = calculate
        # 9000/26 × 13 × 8/16 + 12000/26 × 13 × 8/16 = 2,250 + 3,000
        expect(entry.base_salary).to eq(BigDecimal("5250.00"))
        expect(entry.working_days).to eq(13)
        expect(entry.salary_breakdown_portions.map { |p| p["amount"] }).to eq(%w[2250.00 3000.00])
        expect(entry.salary_breakdown["proration"]).to eq("starter_working_days")
      end

      it "prices absence over the starter's working days at the calendar-weighted rate" do
        monthly(9_000, oct(16))
        monthly(12_000, oct(24))
        (16..25).each { |d| work(oct(d)) } # 10 of 13

        weighted_rate = ((9_000 * 8 + 12_000 * 8) / 16.0 / 26).round(4)
        absence = calculate.payroll_line_items.find_by(item_type: "manual_adjustment")
        expect(absence.description).to eq("Absence deduction (3 day(s))")
        expect(absence.amount.to_f).to eq(-(3 * weighted_rate).round(2))
      end

      it "starter monthly → daily: the monthly part keeps its share of the starter's working days" do
        monthly(9_000, oct(16))
        daily(500, oct(24))
        (16..20).each { |d| work(oct(d)) } # 5 days in the monthly part (13 × 8/16 = 6.5 → 7)
        (24..27).each { |d| work(oct(d)) } # 4 days in the daily part

        entry = calculate
        expect(entry.base_salary).to eq(BigDecimal("4250.00")) # 2,250 + 4 × 500
        expect(entry.salary_type).to eq("daily")
        absence = entry.payroll_line_items.find_by(item_type: "manual_adjustment")
        expect(absence.description).to eq("Absence deduction (2 day(s))")
        expect(absence.amount.to_f).to eq(-(2 * (9_000 / 26.0).round(4)).round(2))
      end

      it "starter daily → monthly: the monthly part is its share of the starter's working days" do
        daily(500, oct(16))
        monthly(12_000, oct(24))
        (16..18).each { |d| work(oct(d)) }

        # 3 × 500 + 12000/26 × 13 × 8/16 = 1,500 + 3,000
        expect(calculate.base_salary).to eq(BigDecimal("4500.00"))
      end
    end
  end

  describe "query count" do
    it "loads salary profiles once for the whole period, not per employee or per day" do
      daily(400, Date.new(2026, 3, 1))
      daily(500, oct(15))
      (1..20).each { |d| work(oct(d)) }
      others = create_list(:user, 2, business: business).each do |other|
        create(:salary_profile, :daily, user: other, base_amount: 300, effective_from: Date.new(2026, 1, 1))
      end

      queries = []
      callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('"salary_profiles"') }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        Payroll::PeriodGenerator.call(business: business, year: 2026, month: 10, generated_by: actor)
      end

      expect(queries.size).to eq(1)
      expect(PayrollEntry.where(user: [ user, *others ]).count).to eq(3)
    end
  end
end
