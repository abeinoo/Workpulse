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
      paid_expense = create(:expense, :pending, business: business, created_by: creator,
                             deduct_from_balance: true)

      described_class.new(paid_expense, actor: approver).approve!

      txn = account.custody_transactions.find_by(txn_type: "expense_deduction", expense_id: paid_expense.id)
      expect(txn).to be_present
      expect(txn.amount).to eq(-paid_expense.amount)
      expect(Finance::CustodyBalance.new(account).current).to eq(1_000 - paid_expense.amount)
    end

    it "creates a FinancialSettlement and audits it as settle_from_custody" do
      account = create(:custody_account, business: business, user: creator)
      paid_expense = create(:expense, :pending, business: business, created_by: creator,
                             deduct_from_balance: true)

      described_class.new(paid_expense, actor: approver).approve!

      settlement = paid_expense.financial_settlements.sole
      expect(settlement.funding_source).to eq(account)
      expect(settlement.amount).to eq(paid_expense.amount)
      expect(paid_expense.reload).to be_settled
      expect(AuditLog.where(auditable: paid_expense, action: "settle_from_custody").count).to eq(1)
    end

    it "settles fully with a NIL-funding-source settlement, no custody transaction, when not paid from balance" do
      account = create(:custody_account, business: business, user: creator)
      unpaid  = create(:expense, :pending, business: business, created_by: creator, deduct_from_balance: false)

      described_class.new(unpaid, actor: approver).approve!

      settlement = unpaid.financial_settlements.sole
      expect(settlement.funding_source).to be_nil
      expect(settlement.amount).to eq(unpaid.amount)
      expect(unpaid.reload).to be_settled
      expect(AuditLog.where(auditable: unpaid, action: "settle_from_custody")).to be_empty
      expect(AuditLog.where(auditable: unpaid, action: "settle_direct").count).to eq(1)
      expect(account.custody_transactions.where(expense_id: unpaid.id)).to be_empty
    end

    it "does not settle at all for an installment expense — payments are recorded later" do
      installment = create(:expense, :pending, business: business, created_by: creator,
                            payment_type: "installment")

      described_class.new(installment, actor: approver).approve!

      expect(installment.financial_settlements).to be_empty
      expect(installment.reload).to be_pending_settlement
    end

    it "allows negative balance — approves even when deduction exceeds balance" do
      account = create(:custody_account, business: business, user: creator)
      big     = create(:expense, :pending, business: business, created_by: creator, amount: 5_000,
                        deduct_from_balance: true)

      result = described_class.new(big, actor: approver).approve!
      expect(result.ok?).to be true
      expect(big.reload.status).to eq("approved")
      expect(Finance::CustodyBalance.new(account).current).to eq(-5_000)
    end

    it "approves successfully and settles in full even when creator has no balance account" do
      result = described_class.new(expense, actor: approver).approve!
      expect(result.ok?).to be true
      expect(expense.reload.status).to eq("approved")
      expect(expense).to be_settled
      expect(expense.financial_settlements.sole.funding_source).to be_nil
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

  describe "#cancel!" do
    it "cancels a draft expense with no financial side-effects" do
      draft = create(:expense, business: business, created_by: creator, deduct_from_balance: false)
      result = described_class.new(draft, actor: creator).cancel!(reason: "No longer needed")
      expect(result.ok?).to be true
      expect(draft.reload.status).to eq("cancelled")
      expect(draft.cancelled_by_id).to eq(creator.id)
      expect(draft.cancelled_at).to be_present
      expect(draft.cancellation_reason).to eq("No longer needed")
      expect(AuditLog.where(auditable: draft, action: "cancel").count).to eq(1)
    end

    it "cancels a pending_approval expense with no financial side-effects" do
      pending = create(:expense, :pending, business: business, created_by: creator, deduct_from_balance: false)
      result = described_class.new(pending, actor: approver).cancel!(reason: "Duplicate request")
      expect(result.ok?).to be true
      expect(pending.reload.status).to eq("cancelled")
    end

    it "reverses the custody deduction and settlement when cancelling an approved expense" do
      account = create(:custody_account, business: business, user: creator)
      Finance::CustodyTransactionCreator.new(account, actor: approver,
        params: { txn_type: "top_up", magnitude: 1_000 }).call
      approved = create(:expense, :pending, business: business, created_by: creator, amount: 200,
                         deduct_from_balance: true)
      described_class.new(approved, actor: approver).approve!
      expect(Finance::CustodyBalance.new(account).current).to eq(800)

      result = described_class.new(approved, actor: approver).cancel!(reason: "Approved by mistake")

      expect(result.ok?).to be true
      expect(approved.reload.status).to eq("cancelled")
      expect(Finance::CustodyBalance.new(account).current).to eq(1_000)

      reversal = account.custody_transactions.find_by(txn_type: "expense_deduction_reversal", expense_id: approved.id)
      expect(reversal).to be_present
      expect(reversal.amount).to eq(200)

      expect(approved.financial_settlements.sum(:amount)).to eq(0)
      expect(AuditLog.where(auditable: approved, action: "cancel").count).to eq(1)
    end

    it "reverses the NIL-funding-source settlement (no custody side-effect) for an expense with no custody deduction" do
      approved = create(:expense, :pending, business: business, created_by: creator, deduct_from_balance: false)
      described_class.new(approved, actor: approver).approve!
      expect(approved.reload).to be_settled

      result = described_class.new(approved, actor: approver).cancel!(reason: "Not needed")
      expect(result.ok?).to be true
      expect(approved.reload.status).to eq("cancelled")
      expect(approved.financial_settlements.sum(:amount)).to eq(0)
      expect(CustodyTransaction.where(expense_id: approved.id)).to be_empty
    end

    it "refuses to cancel a rejected expense" do
      rejected = create(:expense, :rejected, business: business, created_by: creator, deduct_from_balance: false)
      result = described_class.new(rejected, actor: creator).cancel!(reason: "x")
      expect(result.ok?).to be false
      expect(rejected.reload.status).to eq("rejected")
    end

    it "refuses to cancel an already-cancelled expense" do
      cancelled = create(:expense, :cancelled, business: business, created_by: creator, deduct_from_balance: false)
      result = described_class.new(cancelled, actor: creator).cancel!(reason: "x")
      expect(result.ok?).to be false
    end

    # True concurrent access is guarded by `@expense.lock!` (SELECT FOR UPDATE)
    # inside both #cancel! and #transition — whichever transaction acquires
    # the row lock first commits, the other reloads fresh state under the
    # lock and fails its precondition check. Transactional fixtures make a
    # genuine multi-connection race impractical to assert here, so this
    # verifies the resulting mutual-exclusion invariant instead: once a
    # status transition has landed, neither a stale approve! nor a stale
    # cancel! can silently overwrite it into an inconsistent state.
    it "cleanly refuses to cancel an expense that was rejected out from under it" do
      pending = create(:expense, :pending, business: business, created_by: creator, deduct_from_balance: false)
      described_class.new(pending, actor: approver).reject!(reason: "Out of budget")

      result = described_class.new(pending, actor: approver).cancel!(reason: "too late")

      expect(result.ok?).to be false
      expect(pending.reload.status).to eq("rejected")
    end

    it "cleanly refuses to approve an expense that was cancelled out from under it" do
      pending = create(:expense, :pending, business: business, created_by: creator, deduct_from_balance: false)
      described_class.new(pending, actor: creator).cancel!(reason: "No longer needed")

      result = described_class.new(pending, actor: approver).approve!

      expect(result.ok?).to be false
      expect(pending.reload.status).to eq("cancelled")
    end
  end
end
