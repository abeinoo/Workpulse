require "rails_helper"

RSpec.describe Payroll::DeductionWaiverPersistence do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:manager)  { create(:user, :accountant, business: business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, total_deductions: 100.0, net_salary: 4_900.0)
  end

  describe ".capture" do
    it "captures a waived, waivable line item keyed by [user_id, waiver_identity]" do
      li = create(:payroll_line_item, :manual_deduction, payroll_entry: entry, amount: -100.0)
      Payroll::DeductionWaiver.call(line_item: li, action: "waive", actor: manager, reason: "Goodwill")

      captured = described_class.capture(entry.payroll_line_items)
      key = [ employee.id, li.waiver_identity ]

      expect(captured[key]).to include(reason: "Goodwill", waived_by_id: manager.id)
    end

    it "does not capture an active (non-waived) line item" do
      create(:payroll_line_item, :manual_deduction, payroll_entry: entry, amount: -100.0)
      expect(described_class.capture(entry.payroll_line_items)).to be_empty
    end

    it "does not capture a waived item whose type is not on the waivable allowlist" do
      li = create(:payroll_line_item, payroll_entry: entry, item_type: "advance_deduction",
                  amount: -100.0, review_status: "approved")
      li.update_columns(deduction_waived: true, deduction_waiver_reason: "manually forced for this test")

      expect(described_class.capture(entry.payroll_line_items)).to be_empty
    end
  end

  describe ".reapply_to_entry" do
    it "reapplies a captured waiver to the matching rebuilt line item and returns true" do
      old_li = create(:payroll_line_item, :manual_deduction, payroll_entry: entry, amount: -100.0, source_id: 42)
      Payroll::DeductionWaiver.call(line_item: old_li, action: "waive", actor: manager, reason: "Goodwill")
      captured = described_class.capture(entry.payroll_line_items)

      old_li.destroy!
      new_li = create(:payroll_line_item, :manual_deduction, payroll_entry: entry, amount: -100.0, source_id: 42)

      touched = described_class.reapply_to_entry(entry.reload, captured)

      expect(touched).to be true
      expect(new_li.reload.deduction_waived?).to be true
      expect(new_li.deduction_waiver_reason).to eq("Goodwill")
      expect(new_li.deduction_waived_by_id).to eq(manager.id)
    end

    it "returns false and touches nothing when nothing matches" do
      create(:payroll_line_item, :manual_deduction, payroll_entry: entry, amount: -100.0, source_id: 999)
      touched = described_class.reapply_to_entry(entry, { [ employee.id, [ "manual_deduction", 1 ] ] => { reason: "x" } })
      expect(touched).to be false
    end

    it "returns false immediately when captured is blank" do
      expect(described_class.reapply_to_entry(entry, {})).to be false
    end
  end
end
