require "rails_helper"

RSpec.describe Payroll::BulkDeductionWaiver do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:manager)  { create(:user, :accountant, business: business) }

  def entry_with_deduction(amount: -100.0)
    user  = create(:user, business: business)
    entry = create(:payroll_entry, payroll_period: period, user: user,
                   base_salary: 5_000.0, total_deductions: amount.abs, net_salary: 5_000.0 - amount.abs)
    create(:payroll_line_item, :manual_deduction, payroll_entry: entry, amount: amount)
    entry
  end

  let!(:entry_a) { entry_with_deduction }
  let!(:entry_b) { entry_with_deduction }

  describe "waive" do
    it "waives every active manual deduction on the selected entries" do
      result = described_class.call(
        period: period, entry_ids: [ entry_a.id, entry_b.id ],
        action: "waive", actor: manager, reason: "Bulk goodwill"
      )

      expect(result.success?).to be true
      expect(result.applied).to eq(2)

      [ entry_a, entry_b ].each do |e|
        expect(e.reload.net_salary).to eq(5_000.0)
        expect(e.payroll_line_items.first.deduction_waived?).to be true
      end
    end

    it "only affects the selected entries" do
      described_class.call(period: period, entry_ids: [ entry_a.id ], action: "waive", actor: manager, reason: "x")

      expect(entry_a.reload.net_salary).to eq(5_000.0)
      expect(entry_b.reload.net_salary).to eq(4_900.0)
    end

    it "requires a reason" do
      result = described_class.call(period: period, entry_ids: [ entry_a.id ], action: "waive", actor: manager, reason: " ")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.deduction_waiver.errors.reason_required"))
    end

    it "requires the permission" do
      other = create(:user, business: business)
      result = described_class.call(period: period, entry_ids: [ entry_a.id ], action: "waive", actor: other, reason: "x")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.deduction_waiver.errors.permission"))
    end

    it "is blocked on a locked period" do
      period.update!(status: :finalized)
      result = described_class.call(period: period, entry_ids: [ entry_a.id ], action: "waive", actor: manager, reason: "x")
      expect(result.success?).to be false
    end
  end

  describe "restore" do
    before do
      described_class.call(period: period, entry_ids: [ entry_a.id, entry_b.id ], action: "waive", actor: manager, reason: "x")
    end

    it "restores every waived manual deduction on the selected entries" do
      result = described_class.call(
        period: period, entry_ids: [ entry_a.id, entry_b.id ],
        action: "restore", actor: manager, reason: "Reinstating"
      )

      expect(result.success?).to be true
      expect(result.applied).to eq(2)
      expect(entry_a.reload.net_salary).to eq(4_900.0)
      expect(entry_b.reload.net_salary).to eq(4_900.0)
    end
  end
end
