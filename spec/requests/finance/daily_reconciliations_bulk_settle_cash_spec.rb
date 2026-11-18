require "rails_helper"

RSpec.describe "Daily Reconciliations — bulk settle: Receive Cash and destination rules", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms, scope: "business_wide", **attrs)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { scope }
    )
    create(:user, business: business, **attrs).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:cash_actor) do
    user_with("view_daily_reconciliation", "settle_remaining_deposit_balance", "receive_shortage_settlement_cash")
  end
  let(:cashier)  { create(:user, business: business) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let!(:card_pm) { PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true) }

  def make_dr(date, shortage)
    dr = DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                     opened_at: date.to_time + 9.hours, closed_at: date.to_time + 22.hours,
                                     business_date: date)
    RemainingDepositBalance.create!(daily_reconciliation: dr, responsible_user: cashier, created_by: cashier,
                                    business: business, branch: branch, amount: shortage,
                                    remaining_amount: shortage, status: "open")
    dr
  end

  let!(:day1) { make_dr(Date.new(2026, 11, 1), 100) }
  let!(:day2) { make_dr(Date.new(2026, 11, 2), 150) }

  # The index lists only the last 14 business days to users without full
  # history access (DailyReconciliation::INDEX_RECENT_BUSINESS_DAYS) — and the
  # bulk bar needs outstanding shortages among the listed DRs. Pinned so the
  # fixed DR dates stay inside that window (BUG-054):
  # 10/11/2026 10:00 UTC = 13:00 Riyadh → business day 10/11; window 28/10 .. 10/11.
  around { |ex| travel_to(Time.utc(2026, 11, 10, 10, 0)) { ex.run } }

  it "runs on business day 10/11/2026, with both DRs inside the index history window" do
    today = BusinessDay.current(context: business)
    expect(today).to eq(Date.new(2026, 11, 10))
    expect(DailyReconciliation.within_recent_business_days(today)).to include(day1, day2)
  end

  def post_cash(**overrides)
    post bulk_settle_finance_daily_reconciliations_path,
         params: { destination: "cash", ids: [ day1.id, day2.id ], notes: "Paid back at the counter",
                   reference_number: "RC-1" }.merge(overrides)
  end

  def error_for(key) = I18n.t("finance.daily_reconciliations.errors.bulk_settle.#{key}")

  describe "POST bulk_settle destination=cash" do
    it "settles every selected shortage with the Cash payment method, server-computed" do
      sign_in cash_actor
      post_cash(total: "1", amount: "999999")
      expect(response).to redirect_to(finance_daily_reconciliations_path)
      expect(flash[:notice]).to include(cash_pm.display_name)
      rows = RemainingDepositBalanceTransaction.settlements
      expect(rows.sum(:amount)).to eq(250)
      expect(rows.pluck(:payment_method_id).uniq).to eq([ cash_pm.id ])
      expect(CustodyTransaction.count).to eq(0)
      expect(TillDeposit.count).to eq(0)
    end

    it "settles without any notes (field omitted or whitespace) — notes are optional" do
      sign_in cash_actor
      post bulk_settle_finance_daily_reconciliations_path, params: { destination: "cash", ids: [ day1.id ] }
      expect(flash[:notice]).to include(cash_pm.display_name)
      post_cash(ids: [ day2.id ], notes: "  ")
      expect(flash[:notice]).to include(cash_pm.display_name)
      expect(RemainingDepositBalanceTransaction.settlements.pluck(:notes, :payment_method_id))
        .to eq([ [ nil, cash_pm.id ], [ nil, cash_pm.id ] ])
    end

    it "refuses a user without receive_shortage_settlement_cash who submits the request by hand" do
      sign_in user_with("view_daily_reconciliation", "settle_remaining_deposit_balance")
      post_cash
      expect(response).to have_http_status(:redirect)
      expect(RemainingDepositBalance.open.count).to eq(2)
      expect(RemainingDepositBalanceTransaction.settlements).to be_empty
    end

    it "rejects a tampered non-cash payment method" do
      sign_in cash_actor
      post_cash(cash_payment_method_id: card_pm.id)
      expect(flash[:alert]).to eq(error_for(:cash_method_invalid))
      expect(RemainingDepositBalance.open.count).to eq(2)
    end

    it "rejects another business's DR id" do
      other = create(:business)
      foreign = DailyReconciliation.create!(branch: create(:branch, business: other), business: other,
                                            state: "closed", opened_at: 2.days.ago, closed_at: 1.day.ago,
                                            business_date: Date.new(2026, 11, 3))
      sign_in cash_actor
      post_cash(ids: [ day1.id, foreign.id ])
      expect(flash[:alert]).to eq(error_for(:not_found))
      expect(RemainingDepositBalanceTransaction.settlements).to be_empty
    end

    it "does not settle twice on a repeated submission" do
      sign_in cash_actor
      post_cash
      post_cash
      expect(flash[:alert]).to eq(error_for(:already_settled))
      expect(RemainingDepositBalanceTransaction.settlements.count).to eq(2)
    end
  end

  describe "destination parameter" do
    before { sign_in cash_actor }

    it "refuses a missing or unknown destination and settles nothing" do
      post_cash(destination: nil)
      expect(flash[:alert]).to eq(error_for(:destination_invalid))
      post_cash(destination: "card")
      expect(flash[:alert]).to eq(error_for(:destination_invalid))
      expect(RemainingDepositBalance.open.count).to eq(2)
    end
  end

  describe "index bulk bar" do
    it "offers Receive Cash only with the permission" do
      sign_in cash_actor
      get finance_daily_reconciliations_path
      body = CGI.unescapeHTML(response.body)
      expect(body).to include('id="bulk-settle-destination-cash"', 'name="cash_payment_method_id"',
                              I18n.t("finance.daily_reconciliations.index.bulk_settle_cash_explainer"))
      expect(body).not_to include('name="payment_method_id"')

      sign_in user_with("view_daily_reconciliation", "settle_remaining_deposit_balance")
      get finance_daily_reconciliations_path
      expect(response.body).not_to include('id="bulk-settle-destination-cash"')
    end

    it "explains when no active Cash method exists" do
      cash_pm.update!(active: false)
      sign_in cash_actor
      get finance_daily_reconciliations_path
      expect(response.body).to include('id="bulk-settle-no-cash-method"')
      expect(response.body).not_to include('name="cash_payment_method_id"')
    end
  end

  # Item 1 regression: an employee who ALREADY has a custody account was missing
  # from the recipient list because the list required Manage Employee Balances.
  # Owner decision 2026-11-15: settle_remaining_deposit_balance alone is enough
  # (ShortageSettlementRecipientScope, within its branch scope).
  describe "custody recipient list for an employee who already has a custody account" do
    let(:holder)   { create(:user, business: business, first_name: "Existing", last_name: "Holder") }
    let!(:account) { create(:custody_account, business: business, user: holder, branch: branch, current_balance: -35) }
    let(:settler)  { user_with("view_daily_reconciliation", "settle_remaining_deposit_balance") }

    it "lists the existing account for a settle-only user — name, branch and balance" do
      sign_in settler
      get finance_daily_reconciliations_path
      body = CGI.unescapeHTML(response.body)
      expect(body).to include('id="bulk-settle-recipient"', "value=\"#{account.id}\"", "Existing Holder", branch.name)
      expect(body).not_to include('id="bulk-settle-no-recipients"')
    end

    it "lists an account with a negative balance (balance never excludes)" do
      sign_in settler
      get finance_daily_reconciliations_path
      expect(response.body).to include("value=\"#{account.id}\"")
    end

    it "limits a branch-scoped settler to their branches; branch-less accounts stay hidden" do
      branchless = create(:custody_account, business: business,
                                            user: create(:user, business: business, first_name: "No", last_name: "Branch"))
      elsewhere  = create(:custody_account, business: business, branch: create(:branch, business: business),
                                            user: create(:user, business: business))
      manager = user_with("view_daily_reconciliation", "settle_remaining_deposit_balance", scope: "branch")
      branch.update_column(:branch_manager_id, manager.id)
      sign_in manager
      get finance_daily_reconciliations_path(branch_id: "")
      expect(response.body).to include("value=\"#{account.id}\"")
      expect(response.body).not_to include("value=\"#{branchless.id}\"")
      expect(response.body).not_to include("value=\"#{elsewhere.id}\"")
    end

    it "offers branch-less accounts to a business-wide settler" do
      branchless = create(:custody_account, business: business, user: create(:user, business: business))
      sign_in settler
      get finance_daily_reconciliations_path
      expect(response.body).to include("value=\"#{branchless.id}\"")
    end

    it "never lists another business's custody account" do
      foreign = create(:custody_account)
      sign_in settler
      get finance_daily_reconciliations_path
      expect(response.body).not_to include("value=\"#{foreign.id}\"")
    end
  end
end
