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
    context "when an APPROVED cash_incentive adjustment is applied" do
      let(:adjustment) do
        create(:payroll_adjustment, :cash_incentive,
          payroll_period: period,
          user:           employee,
          created_by:     manager,
          review_status:  :approved,
          amount:         500.0
        )
      end

      it "creates a cash_incentive line item mirroring the adjustment's status" do
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

    context "when an APPROVED deduction adjustment is applied" do
      let(:adjustment) do
        create(:payroll_adjustment, :manual_deduction,
          payroll_period: period,
          user:           employee,
          created_by:     manager,
          review_status:  :approved,
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

    # The applier must NEVER hard-code "approved". A pending adjustment yields a
    # pending line item that does not affect net salary until a separate approver
    # approves it — closing the API self-approval path.
    context "when a PENDING adjustment is applied" do
      let(:adjustment) do
        create(:payroll_adjustment, :cash_incentive,
          payroll_period: period,
          user:           employee,
          created_by:     manager,
          review_status:  :pending_review,
          amount:         500.0
        )
      end

      it "creates a pending line item" do
        described_class.call(adjustment: adjustment)
        li = entry.reload.payroll_line_items.find_by(source_type: "PayrollAdjustment", source_id: adjustment.id)
        expect(li.review_status).to eq("pending_review")
      end

      it "does NOT change net_salary or total_bonuses" do
        described_class.call(adjustment: adjustment)
        entry.reload
        expect(entry.total_bonuses).to eq(0.0)
        expect(entry.net_salary).to eq(5_000.0)
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

    # Standalone adjustments (created outside the payroll-review flow) have no
    # payroll_period_id. The applier must still find the correct PayrollEntry by
    # looking up the period by business/month/year.
    context "when the adjustment has no payroll_period_id (standalone)" do
      let(:standalone_adjustment) do
        adj = build(:payroll_adjustment, :manual_deduction, :approved,
          payroll_period: nil,
          business:       business,
          user:           employee,
          created_by:     manager,
          period_month:   period.period_month,
          period_year:    period.period_year,
          amount:         150.0
        )
        adj.save!(validate: false)
        adj
      end

      it "finds the entry by business/period_month/period_year and creates a line item" do
        described_class.call(adjustment: standalone_adjustment)
        li = entry.reload.payroll_line_items.find_by(
          source_type: "PayrollAdjustment", source_id: standalone_adjustment.id
        )
        expect(li).to be_present
        expect(li.item_type).to eq("manual_deduction")
        expect(li.amount).to eq(-150.0)
      end

      it "decrements net_salary on the existing entry" do
        described_class.call(adjustment: standalone_adjustment)
        expect(entry.reload.net_salary).to eq(4_850.0)
      end
    end

    context "when an approved commission adjustment is applied" do
      let(:adjustment) do
        create(:payroll_adjustment, :commission,
          payroll_period: period,
          user:           employee,
          created_by:     manager,
          review_status:  :approved,
          amount:         300.0
        )
      end

      it "creates a commission line item" do
        described_class.call(adjustment: adjustment)
        li = entry.reload.payroll_line_items.find_by(source_type: "PayrollAdjustment", source_id: adjustment.id)
        expect(li).to be_present
        expect(li.item_type).to eq("commission")
        expect(li.amount).to eq(300.0)
      end

      it "increases net_salary by the commission amount" do
        described_class.call(adjustment: adjustment)
        expect(entry.reload.net_salary).to eq(5_300.0)
      end
    end

    context "when an approved penalty adjustment is applied" do
      let(:adjustment) do
        create(:payroll_adjustment, :penalty,
          payroll_period: period,
          user:           employee,
          created_by:     manager,
          review_status:  :approved,
          amount:         150.0
        )
      end

      it "creates a penalty line item with a negative amount" do
        described_class.call(adjustment: adjustment)
        li = entry.reload.payroll_line_items.find_by(source_type: "PayrollAdjustment", source_id: adjustment.id)
        expect(li).to be_present
        expect(li.item_type).to eq("penalty")
        expect(li.amount).to eq(-150.0)
      end

      it "decreases net_salary by the penalty amount" do
        described_class.call(adjustment: adjustment)
        expect(entry.reload.net_salary).to eq(4_850.0)
      end
    end
  end
end
