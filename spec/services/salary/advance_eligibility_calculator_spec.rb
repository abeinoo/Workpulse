require "rails_helper"

RSpec.describe Salary::AdvanceEligibilityCalculator do
  let(:business) { create(:business, max_salary_advance_percentage: 30) }
  let(:user)     { create(:user, business: business) }

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
      before { create(:salary_profile, :monthly, user: user, base_amount: 10_000) }

      it "returns a result with monthly basis" do
        result = described_class.for(user: user)
        expect(result).not_to be_nil
        expect(result.basis).to eq(:monthly)
        expect(result.description_key).to eq("monthly_basis")
      end

      it "calculates max_amount as percentage of base salary" do
        result = described_class.for(user: user)
        expect(result.max_amount).to eq(3_000.0)
      end

      it "sets available equal to max_amount when no outstanding advances" do
        result = described_class.for(user: user)
        expect(result.outstanding).to eq(0.0)
        expect(result.available).to eq(3_000.0)
      end

      context "with an active advance" do
        before do
          req = create(:employee_request, :salary_advance, :approved, user: user, amount: 1_000)
          create(:advance, user: user, remaining_amount: 800, employee_request: req)
          req.update!(status: "paid")
        end

        it "deducts the remaining active advance balance" do
          result = described_class.for(user: user)
          expect(result.outstanding).to eq(800.0)
          expect(result.available).to eq(2_200.0)
        end
      end

      context "with a pending advance request" do
        before { create(:employee_request, :salary_advance, user: user, amount: 500) }

        it "deducts pending request amounts from available" do
          result = described_class.for(user: user)
          expect(result.outstanding).to eq(500.0)
          expect(result.available).to eq(2_500.0)
        end
      end

      context "with an approved (not yet paid) advance request" do
        before { create(:employee_request, :salary_advance, :approved, user: user, amount: 600) }

        it "deducts approved-but-unpaid request amounts" do
          result = described_class.for(user: user)
          expect(result.outstanding).to eq(600.0)
          expect(result.available).to eq(2_400.0)
        end
      end

      context "when outstanding exceeds the max amount" do
        before do
          req = create(:employee_request, :salary_advance, :approved, user: user, amount: 2_000)
          create(:advance, user: user, remaining_amount: 3_500, employee_request: req)
          req.update!(status: "paid")
        end

        it "returns available of zero, not negative" do
          result = described_class.for(user: user)
          expect(result.available).to eq(0.0)
        end
      end

      it "does not double-count a paid request that already created an advance" do
        req = create(:employee_request, :salary_advance, :approved, user: user, amount: 1_000)
        create(:advance, user: user, remaining_amount: 1_000, employee_request: req)
        req.update!(status: "paid")

        result = described_class.for(user: user)
        expect(result.outstanding).to eq(1_000.0)
        expect(result.available).to eq(2_000.0)
      end
    end

    context "daily employee" do
      before { create(:salary_profile, :daily, user: user, base_amount: 300) }

      context "with a recent payroll entry" do
        before do
          create(:payroll_entry, user: user, salary_type: "daily", base_salary: 6_000)
        end

        it "returns a result with daily basis" do
          result = described_class.for(user: user)
          expect(result.basis).to eq(:daily)
          expect(result.description_key).to eq("daily_basis")
        end

        it "uses the most recent payroll entry base_salary as earned_basis" do
          result = described_class.for(user: user)
          expect(result.earned_basis).to eq(6_000.0)
          expect(result.max_amount).to eq(1_800.0)
        end

        it "uses the most recent entry when multiple exist" do
          create(:payroll_entry, user: user, salary_type: "daily", base_salary: 4_000,
                 created_at: 2.months.ago)
          result = described_class.for(user: user)
          expect(result.earned_basis).to eq(6_000.0)
        end
      end

      context "with no payroll entry (attendance fallback)" do
        let(:branch)           { create(:branch, business: business) }
        let(:shift)            { create(:shift, :fixed_time, business: business) }
        let!(:shift_assignment) do
          create(:shift_assignment, user: user, shift: shift, branch: branch,
                 effective_from: 1.year.ago.to_date)
        end

        before do
          # 10 attendance records on distinct dates in the last 30 days
          10.times do |i|
            create(:attendance_record, user: user, branch: branch,
                   shift_assignment: shift_assignment,
                   work_date: (10 - i).days.ago.to_date, status: "present")
          end
        end

        it "falls back to daily_rate × worked days" do
          result = described_class.for(user: user)
          expect(result.basis).to eq(:daily)
          expect(result.earned_basis).to be > 0
        end

        it "excludes absent records from worked-days count" do
          create(:attendance_record, user: user, branch: branch,
                 shift_assignment: shift_assignment,
                 work_date: 11.days.ago.to_date, status: "absent")
          result = described_class.for(user: user)
          daily_rate = Salary::DailyRateCalculator.for(user: user, business: business).daily_rate
          expect(result.earned_basis).to eq((daily_rate * 10).round(2))
        end
      end
    end
  end
end
