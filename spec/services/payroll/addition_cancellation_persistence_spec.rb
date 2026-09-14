require "rails_helper"

RSpec.describe Payroll::AdditionCancellationPersistence do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:manager)  { create(:user, :accountant, business: business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, total_bonuses: 300.0, net_salary: 5_300.0)
  end

  describe ".capture" do
    it "captures a cancelled, cancellable line item keyed by [user_id, waiver_identity]" do
      li = create(:payroll_line_item, :commission, payroll_entry: entry, amount: 300.0)
      Payroll::AdditionCanceller.call(line_item: li, actor: manager, reason: "Entered in error")

      captured = described_class.capture(entry.payroll_line_items)
      key = [ employee.id, li.waiver_identity ]

      expect(captured[key]).to include(reason: "Entered in error", cancelled_by_id: manager.id)
    end

    it "does not capture an active (non-cancelled) line item" do
      create(:payroll_line_item, :commission, payroll_entry: entry, amount: 300.0)
      expect(described_class.capture(entry.payroll_line_items)).to be_empty
    end

    it "captures a cancelled overtime item too — there is no type allowlist" do
      li = create(:payroll_line_item, :overtime, payroll_entry: entry, amount: 200.0)
      Payroll::AdditionCanceller.call(line_item: li, actor: manager, reason: "Not worked")

      captured = described_class.capture(entry.payroll_line_items)
      key = [ employee.id, li.waiver_identity ]

      expect(captured[key]).to include(reason: "Not worked", cancelled_by_id: manager.id)
    end

    it "does not capture a cancelled deduction — deductions are never addition_cancellable" do
      li = create(:payroll_line_item, :late_penalty, payroll_entry: entry, amount: -100.0,
                  review_status: "approved")
      li.update_columns(addition_cancelled: true, addition_cancellation_reason: "manually forced for this test")

      expect(described_class.capture(entry.payroll_line_items)).to be_empty
    end
  end

  describe ".reapply_to_entry" do
    it "reapplies a captured cancellation to the matching rebuilt line item and returns true" do
      old_li = create(:payroll_line_item, :commission, payroll_entry: entry, amount: 300.0, source_id: 42)
      Payroll::AdditionCanceller.call(line_item: old_li, actor: manager, reason: "Entered in error")
      captured = described_class.capture(entry.payroll_line_items)

      old_li.destroy!
      new_li = create(:payroll_line_item, :commission, payroll_entry: entry, amount: 300.0, source_id: 42)

      touched = described_class.reapply_to_entry(entry.reload, captured)

      expect(touched).to be true
      expect(new_li.reload.addition_cancelled?).to be true
      expect(new_li.addition_cancellation_reason).to eq("Entered in error")
      expect(new_li.addition_cancelled_by_id).to eq(manager.id)
    end

    it "returns false and touches nothing when nothing matches" do
      create(:payroll_line_item, :commission, payroll_entry: entry, amount: 300.0, source_id: 999)
      touched = described_class.reapply_to_entry(entry, { [ employee.id, [ "commission", 1 ] ] => { reason: "x" } })
      expect(touched).to be false
    end

    it "returns false immediately when captured is blank" do
      expect(described_class.reapply_to_entry(entry, {})).to be false
    end
  end
end
