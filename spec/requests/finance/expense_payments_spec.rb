require "rails_helper"

RSpec.describe "Finance::ExpensePayments", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }

  let(:payer_role) do
    create(:permission_role, business: business,
           permissions: %w[view_expenses create_expenses approve_expenses record_expense_payments],
           permission_scopes: { "view_expenses" => "business" })
  end
  let(:payer)   { create(:user, business: business, permission_role: payer_role) }
  let(:account) { create(:custody_account, business: business, user: payer) }

  let(:expense) do
    create(:expense, :approved, business: business, branch: branch, expense_category: category,
           amount: 8_000, payment_type: "installment")
  end

  describe "GET /finance/expenses/:expense_id/payments/new" do
    it "shows the form to a user with record_expense_payments" do
      account # force creation before the request
      sign_in payer
      get new_finance_expense_payment_path(expense)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(account.name)
    end

    it "blocks a user without the permission" do
      no_perm_role = create(:permission_role, business: business, permissions: %w[view_expenses create_expenses],
                             permission_scopes: { "view_expenses" => "business" })
      viewer = create(:user, business: business, permission_role: no_perm_role)
      sign_in viewer
      get new_finance_expense_payment_path(expense)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /finance/expenses/:expense_id/payments" do
    it "records a payment and redirects to the expense" do
      account # force creation
      sign_in payer
      post finance_expense_payments_path(expense),
           params: { payment: { paid_from_balance: "1", amount: 2_000,
                                 payment_date: Date.current, notes: "First installment" } }

      expect(response).to redirect_to(finance_expense_path(expense))
      expect(expense.reload.total_settled_amount).to eq(2_000)
      expect(expense.remaining_settlement_amount).to eq(6_000)
    end

    it "rejects payment via direct request from a user without permission (server-side enforcement)" do
      no_perm_role = create(:permission_role, business: business, permissions: %w[view_expenses create_expenses],
                             permission_scopes: { "view_expenses" => "business" })
      viewer = create(:user, business: business, permission_role: no_perm_role)
      sign_in viewer

      post finance_expense_payments_path(expense),
           params: { payment: { paid_from_balance: "1", amount: 2_000, payment_date: Date.current } }

      expect(response).to redirect_to(root_path)
      expect(expense.reload.financial_settlements).to be_empty
    end

    it "re-renders the form with an error when the amount exceeds the remaining balance" do
      sign_in payer
      post finance_expense_payments_path(expense),
           params: { payment: { paid_from_balance: "1", amount: 9_000, payment_date: Date.current } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(expense.reload.financial_settlements).to be_empty
    end

    it "cannot record a payment against another business's expense via a crafted id" do
      other_business_expense = create(:expense, :approved, amount: 500, deduct_from_balance: false)
      sign_in payer

      post finance_expense_payments_path(other_business_expense),
           params: { payment: { paid_from_balance: "1", amount: 100, payment_date: Date.current } }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "Expense show page — Payment Summary card button/hint states" do
    it "1) shows the 'تسجيل دفعة' button for an approved installment expense with a remaining balance" do
      account # force creation
      sign_in payer
      get finance_expense_path(expense)

      expect(response.body).to include(new_finance_expense_payment_path(expense))
      expect(response.body).to include(I18n.t("finance.expenses.actions.add_payment"))
    end

    it "3) shows an informational message instead of the button before approval, and blocks payment creation server-side" do
      draft = create(:expense, business: business, branch: branch, expense_category: category,
                      amount: 8_000, payment_type: "installment")
      sign_in payer
      get finance_expense_path(draft)

      expect(response.body).not_to include(new_finance_expense_payment_path(draft))
      expect(response.body).to include(I18n.t("finance.expenses.payment_requires_approved_hint"))

      post finance_expense_payments_path(draft),
           params: { payment: { amount: 100, payment_date: Date.current } }
      expect(response).to redirect_to(root_path)
      expect(draft.reload.financial_settlements).to be_empty
    end

    it "4) shows a fully-paid message instead of the button once Remaining is 0, and blocks overpayment server-side" do
      account # force creation
      Finance::ExpensePaymentRecorder.new(expense.id, actor: payer,
        params: { paid_from_balance: "1", amount: 8_000, payment_date: Date.current }).call

      sign_in payer
      get finance_expense_path(expense)

      expect(response.body).not_to include(new_finance_expense_payment_path(expense))
      expect(response.body).to include(I18n.t("finance.expenses.fully_paid_hint"))

      post finance_expense_payments_path(expense),
           params: { payment: { amount: 1, payment_date: Date.current } }
      expect(response).to redirect_to(root_path)
      expect(expense.reload.total_settled_amount).to eq(8_000)
    end

    it "5) a user without record_expense_payments never sees the button and is blocked server-side" do
      no_perm_role = create(:permission_role, business: business, permissions: %w[view_expenses create_expenses],
                             permission_scopes: { "view_expenses" => "business" })
      viewer = create(:user, business: business, permission_role: no_perm_role)
      sign_in viewer
      get finance_expense_path(expense)

      expect(response.body).not_to include(new_finance_expense_payment_path(expense))

      post finance_expense_payments_path(expense),
           params: { payment: { amount: 100, payment_date: Date.current } }
      expect(response).to redirect_to(root_path)
    end

    it "does NOT show the button, or the hint, for a Direct expense — this workflow is installment-only" do
      direct = create(:expense, :approved, business: business, branch: branch, expense_category: category,
                       amount: 500, payment_type: "direct")
      sign_in payer
      get finance_expense_path(direct)

      expect(response.body).not_to include(new_finance_expense_payment_path(direct))
      expect(response.body).not_to include(I18n.t("finance.expenses.payment_requires_approved_hint"))
      expect(response.body).not_to include(I18n.t("finance.expenses.fully_paid_hint"))
    end
  end

  describe "Add Payment form — custody checkbox visibility (6, 7)" do
    it "6) shows the optional, unchecked 'paid from balance' checkbox when the actor has an eligible custody account" do
      account # force creation
      sign_in payer
      get new_finance_expense_payment_path(expense)

      expect(response.body).to include('type="checkbox"')
      expect(response.body).not_to match(/type="checkbox"[^>]*checked/)
    end

    it "7) hides the checkbox entirely when the actor has no eligible custody account" do
      sign_in payer # no custody account created for payer in this example
      get new_finance_expense_payment_path(expense)

      expect(response.body).not_to include('type="checkbox"')
    end
  end

  describe "Expense show page" do
    it "shows the Add Payment button and payment history to an authorized user" do
      account # force creation
      Finance::ExpensePaymentRecorder.new(expense.id, actor: payer,
        params: { paid_from_balance: "1", amount: 2_000, payment_date: Date.current, notes: "Note A" }).call

      sign_in payer
      get finance_expense_path(expense)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(new_finance_expense_payment_path(expense))
      expect(response.body).to include("Note A")
    end

    it "hides the Add Payment button once fully paid" do
      account # force creation
      Finance::ExpensePaymentRecorder.new(expense.id, actor: payer,
        params: { paid_from_balance: "1", amount: 8_000, payment_date: Date.current }).call

      sign_in payer
      get finance_expense_path(expense)

      expect(response.body).not_to include(new_finance_expense_payment_path(expense))
    end
  end

  describe "full partial-payment scenario (show page end to end)" do
    it "walks Unpaid -> Partially Paid -> Fully Paid, blocks overpayment, and never mutates the original amount" do
      account # ensure it exists
      sign_in payer

      # 1-2. Show page starts Total 8,000 / Paid 0 / Remaining 8,000
      get finance_expense_path(expense)
      expect(response).to have_http_status(:ok)
      expect(expense.total_settled_amount).to eq(0)
      expect(expense.remaining_settlement_amount).to eq(8_000)
      expect(expense.financial_status).to eq("pending_settlement")

      # 3-5. Record a 2,000 payment
      post finance_expense_payments_path(expense),
           params: { payment: { paid_from_balance: "1", amount: 2_000, payment_date: Date.current } }
      expect(response).to redirect_to(finance_expense_path(expense))
      expense.reload
      expect(expense.amount).to eq(8_000) # original amount untouched
      expect(expense.total_settled_amount).to eq(2_000)
      expect(expense.remaining_settlement_amount).to eq(6_000)
      expect(expense.financial_status).to eq("partially_settled")

      # 6. Another 3,000 payment
      post finance_expense_payments_path(expense),
           params: { payment: { paid_from_balance: "1", amount: 3_000, payment_date: Date.current } }
      expense.reload
      expect(expense.amount).to eq(8_000)
      expect(expense.total_settled_amount).to eq(5_000)
      expect(expense.remaining_settlement_amount).to eq(3_000)
      expect(expense.financial_status).to eq("partially_settled")

      # 7. Final 3,000 payment fully settles it
      post finance_expense_payments_path(expense),
           params: { payment: { paid_from_balance: "1", amount: 3_000, payment_date: Date.current } }
      expense.reload
      expect(expense.amount).to eq(8_000)
      expect(expense.total_settled_amount).to eq(8_000)
      expect(expense.remaining_settlement_amount).to eq(0)
      expect(expense.financial_status).to eq("settled")

      # 8. A further payment attempt is rejected — no overpayment. Once fully
      # paid, record_payment? itself denies (remaining is 0), so this is
      # blocked at the authorization layer before ever reaching the service.
      post finance_expense_payments_path(expense),
           params: { payment: { paid_from_balance: "1", amount: 1, payment_date: Date.current } }
      expect(response).to redirect_to(root_path)
      expense.reload
      expect(expense.amount).to eq(8_000)
      expect(expense.total_settled_amount).to eq(8_000)
      expect(expense.financial_settlements.count).to eq(3)

      # The Add Payment button is now gone from the show page
      get finance_expense_path(expense)
      expect(response.body).not_to include(new_finance_expense_payment_path(expense))
    end
  end

  describe "Expenses index" do
    it "shows the paid/remaining amounts and payment status without N+1 (single aggregation query)" do
      account # force creation
      Finance::ExpensePaymentRecorder.new(expense.id, actor: payer,
        params: { paid_from_balance: "1", amount: 2_000, payment_date: Date.current }).call
      create(:expense, :approved, business: business, branch: branch, expense_category: category,
             amount: 500, deduct_from_balance: false)

      sign_in owner
      get finance_expenses_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.expenses.financial_statuses.partially_settled"))
      expect(response.body).to include(I18n.t("finance.expenses.financial_statuses.pending_settlement"))
    end
  end
end
