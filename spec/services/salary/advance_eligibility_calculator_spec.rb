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
      it "returns nil" do
        expect(described_class.for(user: user)).to be_nil
      end
    end

    context "monthly employee" do
      # base 6,600 / 22 working days = 300/day; 10 complete days → 3,000 earned.
      before do
        business.update!(working_days_per_month: 22)
        create(:salary_profile, :monthly, user: user, base_amount: 6_600)
        10.times { |i| complete_day_this_month(i) }
      end

      it "returns a result with monthly basis" do
        result = described_class.for(user: user)
        expect(result.basis).to eq(:monthly)
        expect(result.description_key).to eq("monthly_basis")
      end

      it "uses salary earned so far this month, not the full contract salary" do
        result = described_class.for(user: user)
        expect(result.earned_basis).to eq(3_000.0)        # 300 × 10
        expect(result.max_amount).to eq(900.0)            # 30% of 3,000
      end

      it "sets available equal to max_amount when no outstanding advances" do
        result = described_class.for(user: user)
        expect(result.outstanding).to eq(0.0)
        expect(result.available).to eq(900.0)
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
          expect(result.available).to eq(100.0)           # 900 − 800
        end
      end

      context "with a pending advance request" do
        before { create(:employee_request, :salary_advance, user: user, amount: 500) }

        it "deducts pending request amounts from available" do
          result = described_class.for(user: user)
          expect(result.outstanding).to eq(500.0)
          expect(result.available).to eq(400.0)           # 900 − 500
        end
      end

      context "with an approved (not yet paid) advance request" do
        before { create(:employee_request, :salary_advance, :approved, user: user, amount: 600) }

        it "deducts approved-but-unpaid request amounts" do
          result = described_class.for(user: user)
          expect(result.outstanding).to eq(600.0)
          expect(result.available).to eq(300.0)           # 900 − 600
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
        req = outstanding_request(amount: 1_000)
        create(:advance, user: user, remaining_amount: 1_000, employee_request: req)
        req.update!(status: "paid")

        result = described_class.for(user: user)
        expect(result.outstanding).to eq(1_000.0)
        expect(result.available).to eq(0.0)               # max(900 − 1000, 0)
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
  end
end
