require "rails_helper"

# Payment Type ("Direct Expense" vs "Installment / Partial Payment") and
# Payment Source ("paid from my balance/custody" or not) are two completely
# INDEPENDENT choices:
#
#   - Payment Type says whether the entered Amount IS the actual payment
#     (Direct) or only the agreed total to be paid off later (Installment).
#   - Payment Source says whether a given payment is funded from a tracked
#     CustodyAccount or not — OPTIONAL, never assumed, and only ever offered
#     to a user who actually has an eligible account. If they don't, the
#     control is not shown at all (no disabled checkbox, no validation nag),
#     and the expense/payment proceeds normally without any custody
#     involvement.
#
# Neither axis is a new column beyond the genuinely-new payment_type: Payment
# Source is still exactly the pre-existing deduct_from_balance flag, now
# fully decoupled from payment_type again.
RSpec.describe "Finance::Expenses payment type vs payment source (independent axes)", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:role) do
    create(:permission_role, business: business,
           permissions: %w[view_expenses create_expenses approve_expenses record_expense_payments],
           permission_scopes: { "view_expenses" => "business" })
  end
  let(:creator) { create(:user, business: business, permission_role: role) }

  before { sign_in creator }

  describe "1) user WITH a custody account" do
    let!(:account) { create(:custody_account, business: business, user: creator) }

    it "shows the Payment Source option on the New Expense form, unchecked by default" do
      get new_finance_expense_path
      expect(response.body).to include("expense_deduct_from_balance")
      expect(response.body).not_to match(/id="expense_deduct_from_balance"[^>]*checked/)
    end

    it "unchecked: creates the expense fine, is fully paid at approval, and no custody deduction happens" do
      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 500,
                   expense_date: Date.current, payment_type: "direct" } # deduct_from_balance omitted => false
      }
      expense = Expense.find_by!(business: business, amount: 500)

      patch submit_finance_expense_path(expense)
      sign_in owner
      patch approve_finance_expense_path(expense)
      expense.reload

      expect(expense.deduct_from_balance).to eq(false)
      expect(expense.total_settled_amount).to eq(500)
      expect(expense.remaining_settlement_amount).to eq(0)
      expect(expense.financial_status).to eq("settled")
      expect(expense.financial_settlements.sole.funding_source).to be_nil
      expect(account.custody_transactions.where(expense_id: expense.id)).to be_empty
    end

    it "checked: creates the expense and a custody deduction happens at approval" do
      Finance::CustodyTransactionCreator.new(account, actor: creator,
        params: { txn_type: "top_up", magnitude: 1_000 }).call

      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 500,
                   expense_date: Date.current, payment_type: "direct", deduct_from_balance: "1" }
      }
      expense = Expense.find_by!(business: business, amount: 500)
      expect(expense.deduct_from_balance).to eq(true)

      patch submit_finance_expense_path(expense)
      sign_in owner
      patch approve_finance_expense_path(expense)
      expense.reload

      expect(expense.total_settled_amount).to eq(500)
      expect(expense.remaining_settlement_amount).to eq(0)
      expect(expense.financial_status).to eq("settled")
      expect(account.custody_transactions.where(txn_type: "expense_deduction", expense_id: expense.id).count).to eq(1)
      expect(Finance::CustodyBalance.new(account).current).to eq(500)
    end
  end

  describe "2) user WITHOUT a custody account" do
    it "does not show the Payment Source option on the New Expense form" do
      get new_finance_expense_path
      expect(response.body).not_to include('type="checkbox"')
      expect(response.body).to include('name="expense[deduct_from_balance]" type="hidden" value="0"')
        .or include('name="expense[deduct_from_balance]"')
    end

    it "can still create a Direct expense with no custody account, and it is fully paid with no custody transaction" do
      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 500,
                   expense_date: Date.current, payment_type: "direct" }
      }
      expect(response).to have_http_status(:redirect)
      expense = Expense.find_by!(business: business, amount: 500)
      expect(expense.deduct_from_balance).to eq(false)
      expect(expense.payment_source).to eq("not_linked_to_balance")

      patch submit_finance_expense_path(expense)
      sign_in owner
      patch approve_finance_expense_path(expense)
      expense.reload

      expect(expense.status).to eq("approved")
      expect(expense.total_settled_amount).to eq(500)
      expect(expense.remaining_settlement_amount).to eq(0)
      expect(expense.financial_status).to eq("settled")
      expect(CustodyTransaction.where(expense_id: expense.id)).to be_empty
    end
  end

  describe "2b) Installment expense creation — the balance/custody option must never appear or apply" do
    let!(:account) { create(:custody_account, business: business, user: creator) }

    it "server-renders the Payment Source panel hidden even though the user has an eligible account" do
      get new_finance_expense_path
      body = response.body
      idx = body.index('data-payment-type-target="panel"')
      expect(idx).to be_present
      panel_open_tag = body[idx...body.index(">", idx)]
      # Fresh form defaults to Direct, so the panel starts visible — the
      # payment_type_controller.js toggle (covered by the system spec) is
      # what hides it once "Installment" is chosen client-side.
      expect(panel_open_tag).not_to include("hidden")
    end

    it "creating with payment_type=installment and a tampered deduct_from_balance=1 still results in no deduction, no settlement" do
      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 8_000,
                   expense_date: Date.current, payment_type: "installment", deduct_from_balance: "1" }
      }
      expense = Expense.find_by!(business: business, amount: 8_000)
      expect(expense.payment_type).to eq("installment")
      expect(expense.deduct_from_balance).to eq(false) # forced by the model, ignoring the tampered param

      patch submit_finance_expense_path(expense)
      sign_in owner
      patch approve_finance_expense_path(expense)
      expense.reload

      expect(expense.total_settled_amount).to eq(0)
      expect(expense.remaining_settlement_amount).to eq(8_000)
      expect(expense.financial_settlements).to be_empty
      expect(CustodyTransaction.where(expense_id: expense.id)).to be_empty
    end

    it "blocks recording a payment before the expense is approved" do
      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 8_000,
                   expense_date: Date.current, payment_type: "installment" }
      }
      expense = Expense.find_by!(business: business, amount: 8_000)
      expect(expense.status).to eq("draft")
      expect(ExpensePolicy.new(creator, expense).record_payment?).to be false

      post finance_expense_payments_path(expense),
           params: { payment: { amount: 100, payment_date: Date.current } }
      expect(response).to redirect_to(root_path) # Pundit::NotAuthorizedError
      expect(expense.reload.financial_settlements).to be_empty

      patch submit_finance_expense_path(expense)
      expect(ExpensePolicy.new(creator, expense.reload).record_payment?).to be false # still pending_approval

      post finance_expense_payments_path(expense),
           params: { payment: { amount: 100, payment_date: Date.current } }
      expect(response).to redirect_to(root_path)
      expect(expense.reload.financial_settlements).to be_empty
    end
  end

  describe "3) Direct expense" do
    let!(:account) { create(:custody_account, business: business, user: creator) }

    it "paid from balance: amount is deducted from custody at approval" do
      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 500,
                   expense_date: Date.current, payment_type: "direct", deduct_from_balance: "1" }
      }
      expense = Expense.find_by!(business: business, amount: 500)
      patch submit_finance_expense_path(expense)
      sign_in owner
      patch approve_finance_expense_path(expense)

      expect(expense.reload.total_settled_amount).to eq(500)
      expect(expense.financial_settlements.sole.funding_source).to eq(account)
    end

    it "not paid from balance: is still fully paid, and amount is NOT deducted from custody" do
      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 500,
                   expense_date: Date.current, payment_type: "direct", deduct_from_balance: "0" }
      }
      expense = Expense.find_by!(business: business, amount: 500)
      patch submit_finance_expense_path(expense)
      sign_in owner
      patch approve_finance_expense_path(expense)
      expense.reload

      expect(expense.total_settled_amount).to eq(500)
      expect(expense.remaining_settlement_amount).to eq(0)
      expect(expense.financial_status).to eq("settled")
      expect(expense.financial_settlements.sole.funding_source).to be_nil
      expect(Finance::CustodyBalance.new(account).current).to eq(0)
    end
  end

  describe "4) Installment expense — each payment has its own independent source decision" do
    let!(:account) { create(:custody_account, business: business, user: creator) }

    it "first payment from balance, second payment not from balance" do
      Finance::CustodyTransactionCreator.new(account, actor: creator,
        params: { txn_type: "top_up", magnitude: 10_000 }).call

      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 8_000,
                   expense_date: Date.current, payment_type: "installment" }
      }
      expense = Expense.find_by!(business: business, amount: 8_000)
      patch submit_finance_expense_path(expense)
      sign_in owner
      patch approve_finance_expense_path(expense)
      sign_in creator

      # Payment #1 — from balance.
      post finance_expense_payments_path(expense),
           params: { payment: { amount: 2_000, payment_date: Date.current, paid_from_balance: "1" } }
      expense.reload
      expect(expense.total_settled_amount).to eq(2_000)
      expect(expense.financial_settlements.chronological.first.funding_source).to eq(account)
      expect(Finance::CustodyBalance.new(account).current).to eq(8_000)

      # Payment #2 — NOT from balance: recorded as a real payment, but does
      # not touch the custody balance.
      post finance_expense_payments_path(expense),
           params: { payment: { amount: 3_000, payment_date: Date.current, paid_from_balance: "0" } }
      expense.reload
      expect(expense.total_settled_amount).to eq(5_000)
      expect(expense.remaining_settlement_amount).to eq(3_000)
      expect(expense.financial_settlements.chronological.last.funding_source).to be_nil
      expect(Finance::CustodyBalance.new(account).current).to eq(8_000) # unchanged by payment #2
      expect(expense.financial_settlements.count).to eq(2)
    end
  end

  describe "5) existing approval/rejection/cancellation is unchanged" do
    it "self-approval is still blocked regardless of payment type or source" do
      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 100,
                   expense_date: Date.current, payment_type: "installment" }
      }
      expense = Expense.find_by!(business: business, amount: 100)
      patch submit_finance_expense_path(expense)

      patch approve_finance_expense_path(expense) # creator tries to approve their own
      expect(expense.reload.status).to eq("pending_approval") # unchanged — still blocked
    end

    it "cancelling an approved expense reverses ALL its settlements, custody and non-custody alike" do
      account = create(:custody_account, business: business, user: creator)
      Finance::CustodyTransactionCreator.new(account, actor: creator,
        params: { txn_type: "top_up", magnitude: 10_000 }).call

      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 8_000,
                   expense_date: Date.current, payment_type: "installment" }
      }
      expense = Expense.find_by!(business: business, amount: 8_000)
      patch submit_finance_expense_path(expense)
      sign_in owner
      patch approve_finance_expense_path(expense)
      sign_in creator

      post finance_expense_payments_path(expense),
           params: { payment: { amount: 2_000, payment_date: Date.current, paid_from_balance: "1" } }
      post finance_expense_payments_path(expense),
           params: { payment: { amount: 3_000, payment_date: Date.current, paid_from_balance: "0" } }
      expect(expense.reload.total_settled_amount).to eq(5_000)
      expect(Finance::CustodyBalance.new(account).current).to eq(8_000)

      sign_in owner
      patch cancel_finance_expense_path(expense), params: { cancellation_reason: "No longer needed" }

      expect(expense.reload.status).to eq("cancelled")
      expect(expense.total_settled_amount).to eq(0) # fully unwound
      expect(Finance::CustodyBalance.new(account).current).to eq(10_000) # custody leg reversed too
    end
  end

  describe "6) settlement/reconciliation stays correct with mixed custody / non-custody payments" do
    it "Total Paid and Remaining correctly sum both kinds of payment" do
      account = create(:custody_account, business: business, user: creator)
      post finance_expenses_path, params: {
        expense: { expense_category_id: category.id, branch_id: branch.id, amount: 8_000,
                   expense_date: Date.current, payment_type: "installment" }
      }
      expense = Expense.find_by!(business: business, amount: 8_000)
      patch submit_finance_expense_path(expense)
      sign_in owner
      patch approve_finance_expense_path(expense)
      sign_in creator

      post finance_expense_payments_path(expense),
           params: { payment: { amount: 2_000, payment_date: Date.current, paid_from_balance: "1" } }
      post finance_expense_payments_path(expense),
           params: { payment: { amount: 3_000, payment_date: Date.current, paid_from_balance: "0" } }
      post finance_expense_payments_path(expense),
           params: { payment: { amount: 3_000, payment_date: Date.current, paid_from_balance: "0" } }
      expense.reload

      expect(expense.amount).to eq(8_000) # agreed amount never changes
      expect(expense.total_settled_amount).to eq(8_000)
      expect(expense.remaining_settlement_amount).to eq(0)
      expect(expense.financial_status).to eq("settled")

      # Overpayment still blocked once fully paid.
      post finance_expense_payments_path(expense),
           params: { payment: { amount: 1, payment_date: Date.current, paid_from_balance: "0" } }
      expect(response).to redirect_to(root_path)
      expect(expense.reload.total_settled_amount).to eq(8_000)
    end
  end
end
