require "rails_helper"

# Regression: an employee whose FIRST salary profile becomes effective partway
# through the payroll month must still receive a PayrollEntry, prorated from their
# effective_from. Previously the profile lookup was anchored to period_start, so any
# profile with effective_from > the 1st of the month resolved to nil and the
# employee silently vanished from payroll.
#
# June 2026 has 30 calendar days; working_days_per_month is set to 30 so the
# calendar-day proration maps 1:1 onto working days and the arithmetic is exact.
RSpec.describe Payroll::EntryCalculator, "mid-month effective_from" do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 30) }
  let(:branch)   { create(:branch, business: business) }
  let(:user)     { create(:user, business: business) }

  let(:shift) do
    create(:shift, :fixed_time, business: business,
           start_time: Time.zone.parse("09:00"),
           end_time:   Time.zone.parse("17:00"))
  end

  # June 2026 (the period being generated).
  let(:period) do
    create(:payroll_period, business: business,
           period_year: 2026, period_month: 6, working_days: 30)
  end
  let(:period_start) { period.period_start }   # 2026-06-01
  let(:period_end)   { period.period_end }      # 2026-06-30

  # Monthly 9,000 SAR → daily_rate = 9000 / 30 = 300.
  let(:base_amount) { 9_000.0 }
  let(:daily_rate)  { base_amount / 30 }

  def create_profile(effective_from)
    create(:salary_profile, :monthly, user: user,
           base_amount: base_amount, effective_from: effective_from)
  end

  def assign_shift(effective_from)
    @assignment = create(:shift_assignment, user: user, branch: branch, shift: shift,
                         effective_from: effective_from)
  end

  # A complete (check-in + check-out) attendance record for every calendar day in
  # the window, so days_worked equals the number of active calendar days. Records are
  # tied to the existing assignment so the factory does not build a conflicting one.
  def fill_attendance(from, to)
    (from..to).each do |date|
      create(:attendance_record, user: user, branch: branch, shift_assignment: @assignment,
             date: date, work_date: date,
             check_in_at:  Time.zone.local(date.year, date.month, date.day, 9, 0),
             check_out_at: Time.zone.local(date.year, date.month, date.day, 17, 0),
             worked_minutes: 480, status: "present")
    end
  end

  def run
    described_class.call(period: period, user: user, business: business)
  end

  context "effective_from on the FIRST day of the month (2026-06-01)" do
    before do
      create_profile(Date.new(2026, 6, 1))
      assign_shift(Date.new(2026, 6, 1))
    end

    it "creates a PayrollEntry" do
      expect { run }.to change(PayrollEntry, :count).by(1)
    end

    it "uses the full period working days and full base salary" do
      entry = run
      expect(entry.working_days).to eq(30)
      expect(entry.base_salary).to eq(base_amount)
    end
  end

  context "effective_from MID-month (2026-06-16) — the reported bug" do
    before do
      create_profile(Date.new(2026, 6, 16))
      assign_shift(Date.new(2026, 6, 16))
    end

    it "still creates a PayrollEntry (no longer excluded)" do
      expect { run }.to change(PayrollEntry, :count).by(1)
    end

    it "prorates working days to the active window (Jun 16–30 = 15 days)" do
      entry = run
      expect(entry.working_days).to eq(15)
    end

    it "prorates base salary to the active window (15 × 300 = 4500)" do
      entry = run
      expect(entry.base_salary).to eq(4_500.0)
    end

    it "does NOT deduct absence for days before effective_from" do
      # Full attendance across the active window → zero absent days.
      fill_attendance(Date.new(2026, 6, 16), Date.new(2026, 6, 30))
      entry = run
      expect(entry.days_worked).to eq(15)
      expect(entry.payroll_line_items.where(item_type: "manual_adjustment")).to be_empty
      expect(entry.net_salary).to eq(4_500.0)
    end
  end

  context "effective_from on the LAST day of the month (2026-06-30)" do
    before do
      create_profile(Date.new(2026, 6, 30))
      assign_shift(Date.new(2026, 6, 30))
    end

    it "still creates a PayrollEntry" do
      expect { run }.to change(PayrollEntry, :count).by(1)
    end

    it "prorates to a single active working day" do
      entry = run
      expect(entry.working_days).to eq(1)
      expect(entry.base_salary).to eq(300.0)
    end
  end

  context "effective_from AFTER the period ends (2026-07-05)" do
    before do
      create_profile(Date.new(2026, 7, 5))
      assign_shift(Date.new(2026, 7, 5))
    end

    it "creates no entry — the employee was not active during this period" do
      expect(run).to be_nil
      expect(PayrollEntry.count).to eq(0)
    end
  end
end
