require "rails_helper"

RSpec.describe Adjustments::BulkCreateService, type: :model do
  let(:business)  { create(:business) }
  let(:creator)   { create(:user, business: business) }
  let(:employee)  { create(:user, business: business) }
  let!(:period)   { create(:payroll_period, business: business, status: "draft", period_month: 6, period_year: 2026) }

  def row(overrides = {})
    {
      user_id:         employee.id,
      adjustment_type: "cash_incentive",
      amount:          "500",
      reason:          "Q2 bonus",
      period_month:    6,
      period_year:     2026
    }.merge(overrides)
  end

  describe "#call" do
    it "creates adjustments as pending_review — never auto-approved" do
      result = described_class.new(rows: [ row ], business: business, created_by: creator).call

      expect(result).to be_success
      adj = PayrollAdjustment.last
      expect(adj.review_status).to eq("pending_review")
      expect(adj.approved_by).to be_nil
      expect(adj.approved_at).to be_nil
    end

    it "does not auto-approve even when the creator can approve_adjustments" do
      allow(creator).to receive(:can?).and_call_original
      allow(creator).to receive(:can?).with(:manage_adjustments).and_return(true)
      allow(creator).to receive(:can?).with(:approve_adjustments).and_return(true)

      described_class.new(rows: [ row ], business: business, created_by: creator).call

      expect(PayrollAdjustment.last.review_status).to eq("pending_review")
      expect(PayrollAdjustment.last.approved_by).to be_nil
    end

    it "blocks the whole batch when the target period is already paid" do
      period.update_column(:status, "paid")

      result = described_class.new(rows: [ row ], business: business, created_by: creator).call

      expect(result).to be_failed
      expect(PayrollAdjustment.count).to eq(0)
      expect(result.row_errors.flat_map(&:messages).join)
        .to include(I18n.t("adjustments.errors.period_processed"))
    end
  end
end
