require "rails_helper"

RSpec.describe EmployeeObligation, type: :model do
  subject(:obligation) { build(:employee_obligation) }

  # ── Associations ──────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:business) }
    it { is_expected.to belong_to(:created_by).class_name("User") }
    it { is_expected.to have_many(:obligation_deductions).dependent(:destroy) }
  end

  # ── Validations ───────────────────────────────────────────────────────────
  describe "validations" do
    it { is_expected.to validate_presence_of(:obligation_type) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:total_amount) }
    it { is_expected.to validate_presence_of(:remaining_amount) }
    it { is_expected.to validate_presence_of(:installment_amount) }
    it { is_expected.to validate_presence_of(:start_month) }
    it { is_expected.to validate_presence_of(:start_year) }

    it "requires start_month to be 1-12" do
      expect(build(:employee_obligation, start_month: 0)).not_to be_valid
      expect(build(:employee_obligation, start_month: 13)).not_to be_valid
      expect(build(:employee_obligation, start_month: 6)).to be_valid
    end

    it "requires start_year > 2000" do
      expect(build(:employee_obligation, start_year: 1999)).not_to be_valid
      expect(build(:employee_obligation, start_year: 2025)).to be_valid
    end

    it "requires end_month and end_year together" do
      expect(build(:employee_obligation, start_month: 1, start_year: 2025, end_month: 6, end_year: nil)).not_to be_valid
      expect(build(:employee_obligation, start_month: 1, start_year: 2025, end_month: nil, end_year: 2025)).not_to be_valid
      expect(build(:employee_obligation, start_month: 1, start_year: 2025, end_month: 6, end_year: 2025)).to be_valid
    end

    it "rejects end period before start period" do
      expect(
        build(:employee_obligation, start_month: 6, start_year: 2025, end_month: 5, end_year: 2025)
      ).not_to be_valid
    end

    it "allows end period equal to start period" do
      expect(
        build(:employee_obligation, start_month: 6, start_year: 2025, end_month: 6, end_year: 2025)
      ).to be_valid
    end

    it "allows end period after start period" do
      expect(
        build(:employee_obligation, start_month: 6, start_year: 2025, end_month: 1, end_year: 2026)
      ).to be_valid
    end
  end

  # ── Instance Methods ──────────────────────────────────────────────────────
  describe "#installment_for_period" do
    it "returns the installment amount when remaining is larger" do
      obligation = build(:employee_obligation, installment_amount: 500, remaining_amount: 3000)
      expect(obligation.installment_for_period).to eq(500.0)
    end

    it "returns the remaining amount when smaller than installment" do
      obligation = build(:employee_obligation, installment_amount: 500, remaining_amount: 200)
      expect(obligation.installment_for_period).to eq(200.0)
    end
  end

  describe "#repay!" do
    let!(:obligation) { create(:employee_obligation, total_amount: 1000, remaining_amount: 1000) }

    it "decrements remaining_amount" do
      obligation.repay!(200)
      expect(obligation.reload.remaining_amount).to eq(800)
    end

    it "does not reduce remaining below zero" do
      obligation.repay!(1500)
      expect(obligation.reload.remaining_amount).to eq(0)
    end

    it "marks as completed when remaining reaches zero" do
      obligation.repay!(1000)
      expect(obligation.reload.status).to eq("completed")
    end

    it "stays active when remaining is still positive" do
      obligation.repay!(500)
      expect(obligation.reload.status).to eq("active")
    end
  end

  describe "#restore!" do
    let!(:obligation) { create(:employee_obligation, total_amount: 1000, remaining_amount: 500, status: "active") }

    it "increments remaining_amount" do
      obligation.restore!(200)
      expect(obligation.reload.remaining_amount).to eq(700)
    end

    it "does not exceed total_amount" do
      obligation.restore!(2000)
      expect(obligation.reload.remaining_amount).to eq(1000)
    end

    it "reactivates a completed obligation when balance restored" do
      obligation.update!(remaining_amount: 0, status: "completed")
      obligation.restore!(100)
      expect(obligation.reload.status).to eq("active")
    end
  end

  describe "#repaid_amount" do
    it "returns the difference between total and remaining" do
      obligation = build(:employee_obligation, total_amount: 1000, remaining_amount: 600)
      expect(obligation.repaid_amount).to eq(400.0)
    end
  end

  describe "#percent_repaid" do
    it "calculates the percentage repaid" do
      obligation = build(:employee_obligation, total_amount: 1000, remaining_amount: 750)
      expect(obligation.percent_repaid).to eq(25.0)
    end

    it "returns 100 when total_amount is zero" do
      obligation = build(:employee_obligation, total_amount: 0, remaining_amount: 0)
      expect(obligation.percent_repaid).to eq(100)
    end
  end

  # ── Scopes ────────────────────────────────────────────────────────────────
  describe ".covering_period" do
    let(:business) { create(:business) }
    let(:user)     { create(:user, business: business) }
    let(:period)   { create(:payroll_period, business: business, period_month: 6, period_year: 2025) }

    it "includes an obligation that starts before and has no end" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 1, start_year: 2025)
      expect(EmployeeObligation.covering_period(period)).to include(obligation)
    end

    it "includes an obligation starting exactly on the period" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 6, start_year: 2025)
      expect(EmployeeObligation.covering_period(period)).to include(obligation)
    end

    it "excludes an obligation that starts after the period" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 7, start_year: 2025)
      expect(EmployeeObligation.covering_period(period)).not_to include(obligation)
    end

    it "excludes an obligation that ends before the period" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 1, start_year: 2025,
                          end_month: 5, end_year: 2025)
      expect(EmployeeObligation.covering_period(period)).not_to include(obligation)
    end

    it "includes an obligation that ends on the period month" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 1, start_year: 2025,
                          end_month: 6, end_year: 2025)
      expect(EmployeeObligation.covering_period(period)).to include(obligation)
    end
  end
end
