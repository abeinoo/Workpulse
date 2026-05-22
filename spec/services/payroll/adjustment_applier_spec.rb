require "rails_helper"

RSpec.describe Payroll::AdjustmentApplier do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:manager)  { create(:user, :super_admin, business: business) }

  let!(:entry) do
    create(:payroll_entry,
      payroll_period: period,
      user:           employee,
      base_salary:    5_000.0,
      net_salary:     5_000.0,
      total_bonuses:  0.0,
      total_deductions: 0.0
    )
  end

  describe ".call" do
    context "when a cash_incentive adjustment is applied" do
      let(:adjustment) do
        create(:payroll_adjustment, :cash_incentive,
          payroll_period: period,
          user:           employee,
          created_by:     manager,
          amount:         500.0
        )
      end

      it "creates a cash_incentive line item linked to the adjustment" do
        described_class.call(adjustment: adjustment)
        li = entry.reload.payroll_line_items.find_by(source_type: "PayrollAdjustment", source_id: adjustment.id)
        expect(li).to be_present
        expect(li.item_type).to eq("cash_incentive")
        expect(li.amount).to eq(500.0)
        expect(li.review_status).to eq("approved")
      end

      it "increments entry total_bonuses and net_salary" do
        described_class.call(adjustment: adjustment)
        entry.reload
        expect(entry.total_bonuses).to eq(500.0)
        expect(entry.net_salary).to eq(5_500.0)
      end
    end

    context "when a deduction adjustment is applied" do
      let(:adjustment) do
        create(:payroll_adjustment, :manual_deduction,
          payroll_period: period,
          user:           employee,
          created_by:     manager,
          amount:         200.0
        )
      end

      it "creates a manual_deduction line item" do
        described_class.call(adjustment: adjustment)
        li = entry.reload.payroll_line_items.find_by(source_type: "PayrollAdjustment", source_id: adjustment.id)
        expect(li).to be_present
        expect(li.item_type).to eq("manual_deduction")
        expect(li.amount).to eq(-200.0)
      end

      it "increments total_deductions and decrements net_salary" do
        described_class.call(adjustment: adjustment)
        entry.reload
        expect(entry.total_deductions).to eq(200.0)
        expect(entry.net_salary).to eq(4_800.0)
      end
    end

    context "when no payroll entry exists yet" do
      it "returns success without creating a line item" do
        adjustment = create(:payroll_adjustment, :cash_incentive,
          payroll_period: period,
          user:           create(:user, business: business),
          created_by:     manager
        )
        result = described_class.call(adjustment: adjustment)
        expect(result.success?).to be true
        expect(result.line_item).to be_nil
      end
    end
  end
end
