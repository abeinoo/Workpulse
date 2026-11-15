require "rails_helper"

RSpec.describe "Daily Reconciliations — bulk settle to custody account", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:actor) do
    user_with("view_daily_reconciliation", "settle_remaining_deposit_balance",
              "view_employee_balances", "manage_employee_balances")
  end
  let(:cashier)   { create(:user, business: business, first_name: "Cash", last_name: "Ier") }
  let(:recipient) { create(:user, business: business, first_name: "Rana", last_name: "Recipient") }
  let!(:account)  { create(:custody_account, business: business, user: recipient) }
  let!(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def make_dr(date, shortage)
    dr = DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                     opened_at: date.to_time + 9.hours, closed_at: date.to_time + 22.hours,
                                     business_date: date)
    RemainingDepositBalance.create!(daily_reconciliation: dr, responsible_user: cashier, created_by: actor,
                                    business: business, branch: branch, amount: shortage,
                                    remaining_amount: shortage, status: "open")
    dr
  end

  let!(:day1) { make_dr(Date.new(2026, 11, 1), 100) }
  let!(:day2) { make_dr(Date.new(2026, 11, 2), 150) }

  def post_settle(**overrides)
    post bulk_settle_finance_daily_reconciliations_path,
         params: { destination: "custody", ids: [ day1.id, day2.id ], custody_account_id: account.id,
                   notes: "Supervisor collected" }.merge(overrides)
  end

  describe "POST bulk_settle" do
    before { sign_in actor }

    it "credits the server-computed total to the selected custody account" do
      post_settle(total: "999999", amount: "1")
      expect(response).to redirect_to(finance_daily_reconciliations_path)
      expect(flash[:notice]).to include(recipient.full_name)
      expect(account.reload.current_balance).to eq(250)
      expect(RemainingDepositBalance.open.count).to eq(0)
    end

    it "ignores a client-submitted payment method — no cash/card/bank settlement is possible" do
      post_settle(payment_method_id: cash_pm.id, reference_number: "TRX-1")
      expect(RemainingDepositBalanceTransaction.settlements.pluck(:payment_method_id, :reference_number).uniq)
        .to eq([ [ nil, nil ] ])
      expect(TillDeposit.count).to eq(0)
      expect(account.reload.current_balance).to eq(250)
    end

    it "settles without any notes (field omitted or whitespace) — notes are optional" do
      post bulk_settle_finance_daily_reconciliations_path,
           params: { destination: "custody", ids: [ day1.id ], custody_account_id: account.id }
      expect(flash[:notice]).to include(recipient.full_name)
      post_settle(ids: [ day2.id ], notes: "   ")
      expect(flash[:notice]).to include(recipient.full_name)
      expect(RemainingDepositBalanceTransaction.settlements.pluck(:notes)).to eq([ nil, nil ])
      expect(account.reload.current_balance).to eq(250)
    end

    it "rejects a request without a recipient and settles nothing" do
      post_settle(custody_account_id: "")
      expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.bulk_settle.recipient_required"))
      expect(RemainingDepositBalance.open.count).to eq(2)
    end

    it "rejects another business's DR id" do
      other = create(:business)
      foreign = DailyReconciliation.create!(branch: create(:branch, business: other), business: other,
                                            state: "closed", opened_at: 2.days.ago, closed_at: 1.day.ago,
                                            business_date: Date.new(2026, 11, 3))
      post_settle(ids: [ day1.id, foreign.id ])
      expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.bulk_settle.not_found"))
      expect(CustodyTransaction.count).to eq(0)
    end

    it "does not double-credit on a repeated submission" do
      post_settle
      post_settle
      expect(flash[:alert]).to eq(I18n.t("finance.daily_reconciliations.errors.bulk_settle.already_settled"))
      expect(account.reload.current_balance).to eq(250)
      expect(CustodyTransaction.count).to eq(2)
    end
  end

  describe "authorization" do
    it "refuses a user without settle_remaining_deposit_balance" do
      sign_in user_with("view_daily_reconciliation", "view_employee_balances", "manage_employee_balances")
      post_settle
      expect(response).to have_http_status(:redirect)
      expect(CustodyTransaction.count).to eq(0)
      expect(RemainingDepositBalance.open.count).to eq(2)
    end

    it "lets a settle-only user (no Employee Balances permission) credit the custody account" do
      sign_in user_with("view_daily_reconciliation", "settle_remaining_deposit_balance")
      post_settle
      expect(flash[:notice]).to include(recipient.full_name)
      expect(account.reload.current_balance).to eq(250)
    end

    it "grants that settle-only user no general custody access" do
      settler = user_with("view_daily_reconciliation", "settle_remaining_deposit_balance")
      sign_in settler
      post_settle
      credit = CustodyTransaction.last

      # The existing custody scope does not even find the account for this user.
      get finance_custody_account_path(account)
      expect(response).to have_http_status(:not_found)

      expect {
        post finance_custody_account_custody_transactions_path(account),
             params: { txn_type: "top_up", magnitude: "500", notes: "manual" }
      }.not_to change(CustodyTransaction, :count)
      expect(response.status).to eq(404).or eq(302)

      patch void_finance_custody_account_custody_transaction_path(account, credit), params: { void_reason: "x" }
      expect(response.status).to eq(404).or eq(302)
      expect(credit.reload.voided_at).to be_nil
      expect(account.reload.current_balance).to eq(250)
    end
  end

  describe "index bulk bar" do
    it "offers the custody recipient picker and no payment method selector" do
      sign_in actor
      get finance_daily_reconciliations_path
      expect(response).to have_http_status(:ok)
      body = CGI.unescapeHTML(response.body)
      expect(body).to include('id="bulk-settle-recipient"', 'name="custody_account_id"', recipient.full_name)
      expect(body).not_to include('name="payment_method_id"')
      expect(body).to include(I18n.t("finance.daily_reconciliations.index.bulk_settle_custody_explainer"))
      expect(body).to include('data-custody-template=', 'id="bulk-settle-destination-custody"')
      expect(body).not_to include('id="bulk-settle-destination-cash"', 'name="cash_payment_method_id"')
    end

    it "offers recipients to a settle-only user, never asking for Manage Employee Balances" do
      sign_in user_with("view_daily_reconciliation", "settle_remaining_deposit_balance")
      get finance_daily_reconciliations_path
      body = CGI.unescapeHTML(response.body)
      expect(body).to include('id="bulk-settle-recipient"', recipient.full_name)
      expect(body).not_to include('id="bulk-settle-no-recipients"')
      expect(body).not_to include(I18n.t("permission_roles.permissions.manage_employee_balances", default: "Manage Employee Balances"))
    end

    it "explains an empty settlement scope without asking for an unrelated permission" do
      account.update!(active: false)
      sign_in user_with("view_daily_reconciliation", "settle_remaining_deposit_balance")
      get finance_daily_reconciliations_path
      body = CGI.unescapeHTML(response.body)
      expect(body).to include(I18n.t("finance.daily_reconciliations.index.bulk_settle_no_recipients_scope"))
      expect(body).not_to include("Manage Employee Balances")
    end
  end

  describe "after settlement" do
    before do
      sign_in actor
      post_settle
    end

    it "labels the settlement on the DR timeline as a Shortage Settlement Deposit, not a payment method" do
      get finance_daily_reconciliation_path(day1)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.custody.transactions.types.shortage_settlement_deposit"))
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.timeline.detail.label_custody_recipient"))
    end

    it "shows the recipient and original cashier on the shortage page" do
      rdb = day1.remaining_deposit_balances.first
      get finance_remaining_deposit_balance_path(rdb)
      expect(response).to have_http_status(:ok)
      expect(CGI.unescapeHTML(response.body)).to include(
        I18n.t("remaining_deposit_balances.show.custody_recipient",
               recipient: recipient.full_name, cashier: cashier.full_name)
      )
    end

    it "lists the credits on the recipient's custody statement without a void action" do
      get finance_custody_account_path(account)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.custody.transactions.types.shortage_settlement_deposit"))
      expect(response.body).not_to include("void_reason")
    end
  end
end
