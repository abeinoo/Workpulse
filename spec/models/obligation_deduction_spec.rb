require "rails_helper"

RSpec.describe ObligationDeduction, type: :model do
  # ── Associations ──────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:employee_obligation) }
    it { is_expected.to belong_to(:payroll_period) }
  end

  # ── Validations ───────────────────────────────────────────────────────────
  describe "validations" do
    subject { build(:obligation_deduction) }

    it { is_expected.to validate_presence_of(:deducted_amount) }
    it { is_expected.to validate_presence_of(:remaining_before) }
    it { is_expected.to validate_presence_of(:remaining_after) }
  end

  # ── Callbacks ─────────────────────────────────────────────────────────────
  describe "before_create callback" do
    it "decrements the obligation balance on create" do
      obligation = create(:employee_obligation, total_amount: 1000, remaining_amount: 1000)
      period     = create(:payroll_period, business: obligation.business)

      expect {
        ObligationDeduction.create!(
          employee_obligation: obligation,
          payroll_period:      period,
          deducted_amount:     500,
          remaining_before:    1000,
          remaining_after:     500
        )
      }.to change { obligation.reload.remaining_amount }.from(1000).to(500)
    end
  end

  describe "before_destroy callback" do
    it "restores the obligation balance on destroy" do
      obligation = create(:employee_obligation, total_amount: 1000, remaining_amount: 1000)
      period     = create(:payroll_period, business: obligation.business)
      deduction  = ObligationDeduction.create!(
        employee_obligation: obligation,
        payroll_period:      period,
        deducted_amount:     500,
        remaining_before:    1000,
        remaining_after:     500
      )

      expect {
        deduction.destroy!
      }.to change { obligation.reload.remaining_amount }.from(500).to(1000)
    end
  end
end
