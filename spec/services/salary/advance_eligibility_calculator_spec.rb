require "rails_helper"

RSpec.describe Salary::AdvanceEligibilityCalculator do
  let(:business) { create(:business, max_salary_advance_percentage: 30) }
  let(:user)     { create(:user, business: business) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let!(:shift_assignment) do
    create(:shift_assignment, user: user, shift: shift, branch: branch,
           effective_from: 1.year.ago.to_date)
  end

  # Creates a COMPLETE (both-punches) attendance record on a date inside the
  # current calendar month, so it counts toward earned salary.
  def complete_day_this_month(day_offset)
    date = Date.current.beginning_of_month + day_offset.days
    create(:attendance_record, :checked_out,
           user: user, branch: branch, shift_assignment: shift_assignment,
           date: date, work_date: date)
  end

  # Builds an outstanding advance request as test scaffolding, skipping the
  # create-time within_advance_limit check (we're verifying the deduction maths,
  # not the limit guard, so the request amount itself need not fit the ceiling).
  def outstanding_request(amount:, status: "approved")
    build(:employee_request, :salary_advance, user: user, amount: amount, status: status)
      .tap { |r| r.save!(validate: false) }
  end

  describe ".for" do
    context "when no advance percentage is configured on the business" do
      before { business.update!(max_salary_advance_percentage: nil) }

      it "returns nil" do
        expect(described_class.for(user: user)).to be_nil
      end
    end

    context "when no active salary profile exists" do
      it "returns a no_profile result instead of nil or an unrestricted limit" do
        result = described_class.for(user: user)
        expect(result).not_to be_nil
        expect(result.no_profile?).to eq(true)
        expect(result.available).to eq(0.0)
        expect(result.basis).to be_nil
      end
    end

    context "monthly employee" do
      # Monthly employees are entitled to their full configured base_amount
      # regardless of worked days — worked days only matter for daily employees.
      before do
        business.update!(working_days_per_month: 22)
        create(:salary_profile, :monthly, user: user, base_amount: 6_600)
      end

      it "returns a result with monthly basis" do
        result = described_class.for(user: user)
        expect(result.basis).to eq(:monthly)
        expect(result.description_key).to eq("monthly_basis")
        expect(result.no_profile?).to eq(false)
      end

      it "uses the full configured monthly salary, not worked days" do
        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(6_600.0)
        expect(result.max_amount).to eq(1_980.0)          # 30% of 6,600
      end

      it "is unaffected by the number of complete days worked this month" do
        10.times { |i| complete_day_this_month(i) }

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(6_600.0)
        expect(result.max_amount).to eq(1_980.0)
      end

      it "sets available equal to max_amount when no outstanding advances" do
        result = described_class.for(user: user)
        expect(result.outstanding).to eq(0.0)
        expect(result.available).to eq(1_980.0)
      end

      # Scenario from the reported bug: 15,000 monthly salary, 50% limit,
      # no attendance punches yet this month — must not show EGP 0.00.
      context "with a 50% limit and 15,000 monthly salary" do
        before do
          business.update!(max_salary_advance_percentage: 50)
          SalaryProfile.find_by(user: user).update_columns(base_amount: 15_000)
        end

        it "makes the full 7,500 available with no punches this month" do
          result = described_class.for(user: user)
          expect(result.available).to eq(7_500.0)
        end

        it "allows requesting 1,000 when there are no outstanding advances" do
          expect(described_class.for(user: user).available).to be >= 1_000.0
        end

        context "with a 3,000 outstanding advance" do
          before do
            req = outstanding_request(amount: 3_000)
            create(:advance, user: user, remaining_amount: 3_000, employee_request: req)
            req.update!(status: "paid")
          end

          it "reduces the remaining available amount to 4,500" do
            expect(described_class.for(user: user).available).to eq(4_500.0)
          end
        end
      end

      context "with a 100% limit" do
        before { business.update!(max_salary_advance_percentage: 100) }

        it "makes the full monthly salary available" do
          expect(described_class.for(user: user).available).to eq(6_600.0)
        end
      end

      context "with a 0% limit" do
        before { business.update!(max_salary_advance_percentage: 0.01) }

        it "makes only a tiny fraction available" do
          result = described_class.for(user: user)
          expect(result.max_amount).to eq(0.66)
        end
      end

      context "with an active advance" do
        before do
          req = outstanding_request(amount: 1_000)
          create(:advance, user: user, remaining_amount: 800, employee_request: req)
          req.update!(status: "paid")
        end

        it "deducts the remaining active advance balance" do
          result = described_class.for(user: user)
          expect(result.outstanding).to eq(800.0)
          expect(result.available).to eq(1_180.0)         # 1,980 − 800
        end
      end

      context "with a pending advance request" do
        before { create(:employee_request, :salary_advance, user: user, amount: 500) }

        it "deducts pending request amounts from available" do
          result = described_class.for(user: user)
          expect(result.outstanding).to eq(500.0)
          expect(result.available).to eq(1_480.0)         # 1,980 − 500
        end
      end

      context "with an approved (not yet paid) advance request" do
        before { create(:employee_request, :salary_advance, :approved, user: user, amount: 600) }

        it "deducts approved-but-unpaid request amounts" do
          result = described_class.for(user: user)
          expect(result.outstanding).to eq(600.0)
          expect(result.available).to eq(1_380.0)         # 1,980 − 600
        end
      end

      context "when outstanding exceeds the max amount" do
        before do
          req = outstanding_request(amount: 2_000)
          create(:advance, user: user, remaining_amount: 3_500, employee_request: req)
          req.update!(status: "paid")
        end

        it "returns available of zero, not negative" do
          expect(described_class.for(user: user).available).to eq(0.0)
        end
      end

      it "does not double-count a paid request that already created an advance" do
        req = outstanding_request(amount: 1_800)
        create(:advance, user: user, remaining_amount: 1_800, employee_request: req)
        req.update!(status: "paid")

        result = described_class.for(user: user)
        expect(result.outstanding).to eq(1_800.0)
        expect(result.available).to eq(180.0)             # 1,980 − 1,800
      end
    end

    context "daily employee" do
      before { create(:salary_profile, :daily, user: user, base_amount: 423) }

      it "returns a result with daily basis" do
        complete_day_this_month(0)
        result = described_class.for(user: user)
        expect(result.basis).to eq(:daily)
        expect(result.description_key).to eq("daily_basis")
      end

      it "computes earned salary live as daily_rate × complete days worked this month" do
        business.update!(max_salary_advance_percentage: 40)
        12.times { |i| complete_day_this_month(i) }

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(5_076.0)        # 423 × 12
        expect(result.max_amount).to eq(2_030.40)         # 40% of 5,076
        expect(result.available).to eq(2_030.40)
      end

      it "excludes incomplete (single-punch) days from earned salary" do
        complete_day_this_month(0)
        complete_day_this_month(1)
        # Open record: check-in only, no check-out → not complete, not earned.
        date = Date.current.beginning_of_month + 2.days
        create(:attendance_record, user: user, branch: branch,
               shift_assignment: shift_assignment, date: date, work_date: date,
               check_in_at: date.to_time.change(hour: 9), status: "incomplete")

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(846.0)          # 423 × 2 only
      end

      it "excludes absent days from earned salary" do
        complete_day_this_month(0)
        date = Date.current.beginning_of_month + 1.day
        create(:attendance_record, user: user, branch: branch,
               shift_assignment: shift_assignment, date: date, work_date: date,
               status: "absent")

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(423.0)          # 1 complete day
      end

      it "ignores attendance from previous payroll cycles" do
        complete_day_this_month(0)
        # A complete day in the prior month must NOT inflate this cycle's basis.
        prev = Date.current.beginning_of_month - 5.days
        create(:attendance_record, :checked_out, user: user, branch: branch,
               shift_assignment: shift_assignment, date: prev, work_date: prev)

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(423.0)          # only the in-cycle day
      end
    end

    # The core guarantee: eligibility is derived purely from attendance + the active
    # salary profile, so generating or regenerating payroll cannot move the limit.
    context "independence from payroll generation/regeneration" do
      before do
        business.update!(max_salary_advance_percentage: 40)
        create(:salary_profile, :daily, user: user, base_amount: 423)
        12.times { |i| complete_day_this_month(i) }
      end

      it "is unaffected by the presence of a recent PayrollEntry" do
        baseline = described_class.for(user: user).earned_basis

        # A stale/regenerated entry with a wildly different base_salary must not matter.
        create(:payroll_entry, user: user, salary_type: "daily",
               base_salary: 99_999, created_at: Time.current)

        expect(described_class.for(user: user).earned_basis).to eq(baseline)
        expect(baseline).to eq(5_076.0)
      end

      it "returns the same result before and after payroll regeneration" do
        before_regen = described_class.for(user: user).available

        # Simulate regeneration churn: destroy and recreate entries with new
        # created_at timestamps and different snapshot values.
        create(:payroll_entry, user: user, salary_type: "daily",
               base_salary: 1_000, created_at: 2.months.ago)
        PayrollEntry.where(user: user).destroy_all
        create(:payroll_entry, user: user, salary_type: "daily",
               base_salary: 50_000, created_at: Time.current)

        after_regen = described_class.for(user: user).available

        expect(after_regen).to eq(before_regen)
        expect(after_regen).to eq(2_030.40)
      end
    end

    # Explicit August-vs-September coverage: "every calendar month is an
    # independent earning cycle for NEW advance eligibility." Pins the exact
    # worked example from the business-rule clarification (200 EGP/day, 5
    # September days, 50% → 500 available) and proves August activity — worked
    # days, earned wages, and payroll payment status — has zero effect on
    # September's calculation. This is the *new-advance-eligibility* concept;
    # Payroll::AdvanceDeductor and payroll-period ownership are a separate,
    # already-covered concern (see advance_period_isolation_spec.rb).
    context "monthly isolation for a daily employee (August vs September 2026)" do
      around { |ex| travel_to(Time.zone.local(2026, 9, 14, 12, 0, 0)) { ex.run } }

      before do
        business.update!(max_salary_advance_percentage: 50)
        create(:salary_profile, :daily, user: user, base_amount: 200, effective_from: Date.new(2026, 1, 1))
      end

      def complete_day(date)
        create(:attendance_record, :checked_out, user: user, branch: branch,
               shift_assignment: shift_assignment, date: date, work_date: date)
      end

      it "at the start of September with zero September attendance, available is 0 even with 20 complete August days" do
        20.times { |i| complete_day(Date.new(2026, 8, 1) + i.days) }

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(0.0)
        expect(result.available).to eq(0.0)
      end

      it "5 completed September days produce eligibility based only on those 5 days (500 EGP, per the worked example)" do
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(1_000.0)   # 5 × 200
        expect(result.max_amount).to eq(500.0)        # 1,000 × 50%
        expect(result.available).to eq(500.0)
      end

      it "August days mixed with September days: only the September days count" do
        20.times { |i| complete_day(Date.new(2026, 8, 1) + i.days) }
        5.times  { |i| complete_day(Date.new(2026, 9, 1) + i.days) }

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(1_000.0)   # August's 20 days excluded entirely
        expect(result.available).to eq(500.0)
      end

      it "August payroll being paid or unpaid has no effect on September eligibility" do
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }

        unpaid_result = described_class.for(user: user).available

        august_period = create(:payroll_period, :paid, business: business,
               period_year: 2026, period_month: 8, working_days: 22)
        create(:payroll_entry, user: user, payroll_period: august_period,
               salary_type: "daily", base_salary: 4_000, net_salary: 4_000)

        paid_result = described_class.for(user: user).available

        expect(paid_result).to eq(unpaid_result)
        expect(paid_result).to eq(500.0)
      end

      it "still correctly subtracts an existing outstanding advance balance within the September-only basis" do
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }
        req = outstanding_request(amount: 200)
        create(:advance, user: user, remaining_amount: 200, employee_request: req)
        req.update!(status: "paid")

        result = described_class.for(user: user)
        expect(result.max_amount).to eq(500.0)
        expect(result.outstanding).to eq(200.0)
        expect(result.available).to eq(300.0)         # 500 − 200
      end
    end

    # Business-rule correction: a PRIOR month's outstanding advance balance
    # must NEVER reduce the CURRENT month's new-advance allowance, no matter
    # whether that prior debt is repaid, unpaid, or its holding payroll period
    # is paid/unpaid. Only an advance/pending request belonging to THIS month
    # counts against THIS month's cap (guards same-month double-requesting).
    # Existing advance repayment (Payroll::AdvanceDeductor) is untouched and
    # keeps collecting prior-month debt via payroll deductions — this is a
    # separate "how much NEW money right now" question. See
    # advance_period_isolation_spec.rb for payroll-side coverage.
    context "monthly-independent new-advance eligibility (business rule correction)" do
      around { |ex| travel_to(Time.zone.local(2026, 9, 14, 12, 0, 0)) { ex.run } }

      before do
        business.update!(max_salary_advance_percentage: 50)
        create(:salary_profile, :daily, user: user, base_amount: 200, effective_from: Date.new(2026, 1, 1))
      end

      def complete_day(date)
        create(:attendance_record, :checked_out, user: user, branch: branch,
               shift_assignment: shift_assignment, date: date, work_date: date)
      end

      def issue_advance(amount:, issued_at:)
        req = build(:employee_request, :salary_advance, user: user, amount: amount,
                    requested_for_date: issued_at.to_date)
        req.save!(validate: false)
        advance = create(:advance, user: user, employee_request: req,
               total_amount: amount, remaining_amount: amount, issued_at: issued_at)
        req.update_column(:status, "paid")
        advance
      end

      # 1. No August advance, 5 September days → 500 available.
      it "with 5 September days and no prior advance, available is 500" do
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(1_000.0)
        expect(result.max_amount).to eq(500.0)
        expect(result.available).to eq(500.0)
      end

      # 2. 5 September days AND 2,000 outstanding from August → still 500.
      it "with 5 September days and a 2,000 outstanding August advance, available is still 500" do
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }
        issue_advance(amount: 2_000, issued_at: Date.new(2026, 8, 16))

        result = described_class.for(user: user)
        expect(result.max_amount).to eq(500.0)
        expect(result.available).to eq(500.0)
      end

      # 3 & 4. August payroll unpaid vs. paid — no effect either way.
      it "is unchanged whether August's payroll is unpaid or paid" do
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }
        issue_advance(amount: 2_000, issued_at: Date.new(2026, 8, 16))

        unpaid_period = create(:payroll_period, :finalized, business: business,
               period_year: 2026, period_month: 8, working_days: 22)
        create(:payroll_entry, user: user, payroll_period: unpaid_period,
               salary_type: "daily", base_salary: 4_000, net_salary: 4_000)
        unpaid_available = described_class.for(user: user).available
        expect(unpaid_available).to eq(500.0)

        unpaid_period.update!(status: "paid")
        paid_available = described_class.for(user: user).available

        expect(paid_available).to eq(unpaid_available)
        expect(paid_available).to eq(500.0)
      end

      # 5. Outstanding advances spread across MULTIPLE previous months don't
      # reduce this month's allowance either.
      it "outstanding advances from multiple previous months do not reduce this month's allowance" do
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }
        issue_advance(amount: 1_000, issued_at: Date.new(2026, 6, 10))
        issue_advance(amount: 1_500, issued_at: Date.new(2026, 7, 20))
        issue_advance(amount: 2_000, issued_at: Date.new(2026, 8, 16))

        result = described_class.for(user: user)
        expect(result.outstanding).to eq(0.0)
        expect(result.available).to eq(500.0)
      end

      # 6 & 7. August attendance never contributes; September attendance does.
      it "counts only September attendance toward earned_basis, never August's" do
        20.times { |i| complete_day(Date.new(2026, 8, 1) + i.days) }
        5.times  { |i| complete_day(Date.new(2026, 9, 1) + i.days) }

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(1_000.0) # 5 × 200 only
      end

      # 8. A same-month advance/request still correctly reduces THIS month's
      # allowance — existing repayment/limit-guard behavior is unchanged.
      it "still subtracts an advance issued THIS month from this month's allowance" do
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }
        issue_advance(amount: 150, issued_at: Date.new(2026, 9, 10))

        result = described_class.for(user: user)
        expect(result.outstanding).to eq(150.0)
        expect(result.available).to eq(350.0) # 500 − 150
      end

      # 9. Requesting a new September advance must not touch August's Advance
      # records at all — repayment/remaining_amount stays exactly as it was.
      it "does not modify or repay the prior month's Advance record" do
        august_advance = issue_advance(amount: 2_000, issued_at: Date.new(2026, 8, 16))
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }

        expect { described_class.for(user: user) }.not_to change { august_advance.reload.attributes }
      end
    end

    # 10. Eligibility resets independently every calendar month — August's own
    # eligibility is unaffected by September's attendance/requests, and vice
    # versa. A standalone context (no `around`-level travel_to) so the two
    # months can be visited sequentially without nesting travel_to blocks.
    context "eligibility resets independently per calendar month" do
      before do
        business.update!(max_salary_advance_percentage: 50)
        create(:salary_profile, :daily, user: user, base_amount: 200, effective_from: Date.new(2026, 1, 1))
      end

      def complete_day(date)
        create(:attendance_record, :checked_out, user: user, branch: branch,
               shift_assignment: shift_assignment, date: date, work_date: date)
      end

      it "August's own eligibility is unaffected by September's later activity" do
        travel_to(Time.zone.local(2026, 8, 20, 12, 0, 0)) do
          10.times { |i| complete_day(Date.new(2026, 8, 1) + i.days) }

          august_result = described_class.for(user: user)
          expect(august_result.earned_basis).to eq(2_000.0) # 10 × 200
          expect(august_result.available).to eq(1_000.0)    # 50%
        end

        travel_to(Time.zone.local(2026, 9, 14, 12, 0, 0)) do
          5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }

          september_result = described_class.for(user: user)
          expect(september_result.earned_basis).to eq(1_000.0) # 5 × 200, September only
        end
      end
    end

    # Critical acceptance scenario reported in production: user #53,
    # 2026-09-14 — 5 completed September days, daily_rate 461.53, 50% limit,
    # 5,407 EGP outstanding entirely from August advances (#134/#155/#165).
    # Expected: available = 1,153.83, NOT 0.
    context "critical acceptance test: real affected employee (#53-shaped scenario)" do
      around { |ex| travel_to(Time.zone.local(2026, 9, 14, 12, 0, 0)) { ex.run } }

      before do
        business.update!(max_salary_advance_percentage: 50)
        create(:salary_profile, :daily, user: user, base_amount: 461.53, effective_from: Date.new(2026, 6, 1))
      end

      def complete_day(date)
        create(:attendance_record, :checked_out, user: user, branch: branch,
               shift_assignment: shift_assignment, date: date, work_date: date)
      end

      it "returns 1,153.83 available, not 0, despite 5,407 in unpaid August advances" do
        5.times { |i| complete_day(Date.new(2026, 9, 1) + i.days) }

        [ [ 2_307.0, Date.new(2026, 8, 16) ],
          [ 1_600.0, Date.new(2026, 8, 25) ],
          [ 1_500.0, Date.new(2026, 8, 31) ] ].each do |amount, issued_at|
          req = build(:employee_request, :salary_advance, user: user, amount: amount,
                      requested_for_date: issued_at.to_date)
          req.save!(validate: false)
          create(:advance, user: user, employee_request: req,
                 total_amount: amount, remaining_amount: amount, issued_at: issued_at)
          req.update_column(:status, "paid")
        end

        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(2_307.65)
        expect(result.max_amount).to eq(1_153.83)
        expect(result.outstanding).to eq(0.0)     # August advances excluded
        expect(result.available).to eq(1_153.83)
      end
    end
  end
end
