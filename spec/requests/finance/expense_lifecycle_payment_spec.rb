require "rails_helper"

# End-to-end coverage for the "painter" scenario: create an expense for the
# full agreed amount with NO payment yet, submit/approve it through the
# existing (unmodified) approval workflow, then record several partial
# payments through the existing ExpensePaymentRecorder / FinancialSettlement /
# CustodyTransaction stack — verifying the agreed amount never changes, every
# payment stays its own ledger row, overpayment is blocked, and custody
# balances move exactly as expected.
RSpec.describe "Finance::Expenses full agreed-amount vs paid-amount lifecycle", type: :request do
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
  let(:payer)   { create(:user, business: business, permission_role: role) }
  let(:account) { create(:custody_account, business: business, user: payer) }

  it "walks Unpaid -> Partially Paid -> Fully Paid from creation, blocks overpayment, and leaves the agreed amount untouched" do
    account # ensure the custody account exists before any request
    sign_in creator

    # 1. Create the expense for the full agreed amount, explicitly choosing
    #    the Installment payment type — the 8,000 must NOT be recorded as a
    #    payment.
    post finance_expenses_path, params: {
      expense: {
        expense_category_id: category.id, branch_id: branch.id, amount: 8_000,
        expense_date: Date.current, payment_type: "installment"
      }
    }
    expense = Expense.find_by!(business: business, amount: 8_000)
    expect(response).to redirect_to(finance_expense_path(expense)) # lands on the Show page

    # 2. Fresh expense: Paid = 0, Remaining = 8,000, Unpaid — and not yet
    #    payable (draft, not approved).
    expect(expense.amount).to eq(8_000)
    expect(expense.total_settled_amount).to eq(0)
    expect(expense.remaining_settlement_amount).to eq(8_000)
    expect(expense.financial_status).to eq("pending_settlement")
    expect(ExpensePolicy.new(creator, expense).record_payment?).to be false

    # Existing, unmodified submit -> approve workflow (self-approval blocked,
    # so a different user with approve_expenses approves it).
    patch submit_finance_expense_path(expense)
    expect(expense.reload.status).to eq("pending_approval")

    sign_in owner
    patch approve_finance_expense_path(expense)
    expense.reload
    expect(expense.status).to eq("approved")
    expect(expense.amount).to eq(8_000) # approval never touches the agreed amount
    expect(expense.total_settled_amount).to eq(0) # installment type — no auto-payment on approval

    sign_in payer

    # 3-4. Record payment #1 of 2,000 from the existing employee-custody source.
    post finance_expense_payments_path(expense),
         params: { payment: { paid_from_balance: "1", amount: 2_000,
                               payment_date: Date.current, notes: "First installment" } }
    expense.reload
    expect(expense.amount).to eq(8_000)
    expect(expense.total_settled_amount).to eq(2_000)
    expect(expense.remaining_settlement_amount).to eq(6_000)
    expect(expense.financial_status).to eq("partially_settled")

    # 5-6. Payment #2 of 3,000.
    post finance_expense_payments_path(expense),
         params: { payment: { paid_from_balance: "1", amount: 3_000, payment_date: Date.current } }
    expense.reload
    expect(expense.amount).to eq(8_000)
    expect(expense.total_settled_amount).to eq(5_000)
    expect(expense.remaining_settlement_amount).to eq(3_000)
    expect(expense.financial_status).to eq("partially_settled")

    # 7-8. Payment #3 of 3,000 — fully settles it.
    post finance_expense_payments_path(expense),
         params: { payment: { paid_from_balance: "1", amount: 3_000, payment_date: Date.current } }
    expense.reload
    expect(expense.amount).to eq(8_000)
    expect(expense.total_settled_amount).to eq(8_000)
    expect(expense.remaining_settlement_amount).to eq(0)
    expect(expense.financial_status).to eq("settled")

    # 9. A further 1 EGP payment attempt is blocked — no overpayment. Once
    #    fully paid, record_payment? itself denies it server-side.
    expect(ExpensePolicy.new(payer, expense).record_payment?).to be false
    post finance_expense_payments_path(expense),
         params: { payment: { paid_from_balance: "1", amount: 1, payment_date: Date.current } }
    expect(response).to redirect_to(root_path)
    expense.reload
    expect(expense.amount).to eq(8_000)
    expect(expense.total_settled_amount).to eq(8_000)

    # 10. Every payment survives as its own separate, immutable ledger row.
    expect(expense.financial_settlements.count).to eq(3)
    expect(expense.financial_settlements.pluck(:amount).sort).to eq([ 2_000, 3_000, 3_000 ].sort.map(&:to_d))

    # 11. The original agreed amount is untouched throughout.
    expect(expense.reload.amount).to eq(8_000)

    # 12. The custody account's ledger balance reflects every deduction
    #     exactly (mirrors the same expense_deduction txn_type ExpenseApproval
    #     uses for its own full-amount auto-deduction).
    expect(Finance::CustodyBalance.new(account).current).to eq(-8_000)
    expect(account.custody_transactions.where(txn_type: "expense_deduction", expense_id: expense.id).count).to eq(3)

    # 13. Existing approve/reject/cancel behavior is unchanged: a SEPARATE,
    #     deduct_from_balance-checked expense still auto-settles in one shot
    #     at approval exactly as before, and self-approval is still blocked.
    sign_in creator
    creator_account = create(:custody_account, business: business, user: creator)
    auto_expense = create(:expense, :pending, business: business, branch: branch,
                           expense_category: category, created_by: creator, deduct_from_balance: true,
                           reference_number: "EXP-AUTO-001")
    expect(ExpensePolicy.new(creator, auto_expense).approve?).to be false # self-approval blocked

    sign_in owner
    patch approve_finance_expense_path(auto_expense)
    auto_expense.reload
    expect(auto_expense.status).to eq("approved")
    expect(auto_expense.total_settled_amount).to eq(auto_expense.amount) # fully auto-paid, as before
    expect(Finance::CustodyBalance.new(creator_account).current).to eq(-auto_expense.amount)
  end
end
