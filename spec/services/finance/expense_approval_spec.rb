require "rails_helper"

RSpec.describe Finance::ExpenseApproval, type: :model do
  let(:business) { create(:business) }
  let(:creator)  { create(:user, business: business) }
  let(:approver) { create(:user, business: business) }
  let(:expense)  { create(:expense, business: business, created_by: creator, status: status) }

  describe "draft -> pending_approval (submit)" do
    let(:status) { "draft" }
    it "transitions and audits" do
      result = described_class.new(expense, actor: creator).submit!
      expect(result.ok?).to be true
      expect(expense.reload.status).to eq("pending_approval")
      expect(AuditLog.where(auditable: expense, action: "submit").count).to eq(1)
    end
  end

  describe "pending -> approved (approve)" do
    let(:status) { "pending_approval" }

    it "approves when actor is not the creator, stamping approver + time" do
      result = described_class.new(expense, actor: approver).approve!
      expect(result.ok?).to be true
      expect(expense.reload.status).to eq("approved")
      expect(expense.approved_by_id).to eq(approver.id)
      expect(expense.approved_at).to be_present
    end

    it "BLOCKS self-approval by the creator" do
      result = described_class.new(expense, actor: creator).approve!
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("approvals.errors.self_approval"))
      expect(expense.reload.status).to eq("pending_approval")
    end

    it "posts an expense_deduction on the creator's balance account" do
      account = create(:custody_account, business: business, user: creator)
      Finance::CustodyTransactionCreator.new(account, actor: approver,
        params: { txn_type: "top_up", magnitude: 1_000 }).call

      described_class.new(expense, actor: approver).approve!

      txn = account.custody_transactions.find_by(txn_type: "expense_deduction", expense_id: expense.id)
      expect(txn).to be_present
      expect(txn.amount).to eq(-expense.amount)
      expect(Finance::CustodyBalance.new(account).current).to eq(1_000 - expense.amount)
    end

    it "allows negative balance — approves even when deduction exceeds balance" do
      account = create(:custody_account, business: business, user: creator)
      big     = create(:expense, :pending, business: business, created_by: creator, amount: 5_000)

      result = described_class.new(big, actor: approver).approve!
      expect(result.ok?).to be true
      expect(big.reload.status).to eq("approved")
      expect(Finance::CustodyBalance.new(account).current).to eq(-5_000)
    end

    it "approves successfully even when creator has no balance account" do
      result = described_class.new(expense, actor: approver).approve!
      expect(result.ok?).to be true
      expect(expense.reload.status).to eq("approved")
    end
  end

  describe "pending -> rejected (reject)" do
    let(:status) { "pending_approval" }
    it "records the reason and blocks self-rejection" do
      ok = described_class.new(expense, actor: approver).reject!(reason: "Out of budget")
      expect(ok.ok?).to be true
      expect(expense.reload.status).to eq("rejected")
      expect(expense.rejection_reason).to eq("Out of budget")

      e2 = create(:expense, :pending, business: business, created_by: creator)
      expect(described_class.new(e2, actor: creator).reject!(reason: "x").ok?).to be false
    end
  end

  describe "invalid transitions" do
    let(:status) { "draft" }
    it "refuses to approve a draft" do
      result = described_class.new(expense, actor: approver).approve!
      expect(result.ok?).to be false
      expect(expense.reload.status).to eq("draft")
    end
  end

  describe "owner self-approval exception" do
    let(:status) { "pending_approval" }
    it "lets a business owner approve their OWN expense" do
      owner = create(:user, :owner, business: business)
      own   = create(:expense, :pending, business: business, created_by: owner)
      result = described_class.new(own, actor: owner).approve!
      expect(result.ok?).to be true
      expect(own.reload.status).to eq("approved")
    end
  end
end
