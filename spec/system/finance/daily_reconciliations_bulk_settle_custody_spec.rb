require "rails_helper"

# Bulk settlement into a custody account, in the browser: select days, see the
# total, pick the recipient, confirm with recipient + amount, land settled.
RSpec.describe "Daily Reconciliations — bulk settle to custody account", type: :system do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }

  def user_with(*perms, **attrs)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business, **attrs).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:actor) do
    user_with("view_daily_reconciliation", "settle_remaining_deposit_balance",
              "view_employee_balances", "manage_employee_balances", first_name: "Sara", last_name: "Finance")
  end
  let(:cashier)   { create(:user, business: business, first_name: "Omar", last_name: "Cashier") }
  let(:recipient) { create(:user, business: business, first_name: "Rana", last_name: "Recipient") }
  let!(:account)  { create(:custody_account, business: business, user: recipient) }

  # Recent days (the index has a history window), on two branches, viewed
  # with the branch filter cleared ("all branches").
  def make_dr(date, shortage, on: branch)
    dr = DailyReconciliation.create!(branch: on, business: business, state: "closed",
                                     opened_at: date.to_time + 9.hours, closed_at: date.to_time + 22.hours,
                                     business_date: date)
    rdb = RemainingDepositBalance.create!(daily_reconciliation: dr, responsible_user: cashier, created_by: actor,
                                          business: business, branch: on, amount: shortage,
                                          remaining_amount: shortage, status: "open")
    [ dr, rdb ]
  end

  let(:today)  { BusinessDay.current(context: business) }
  let!(:day1) { make_dr(today - 2, 100) }
  let!(:day2) { make_dr(today - 1, 150, on: branch_b) }

  before do
    sign_in actor
    visit finance_daily_reconciliations_path(branch_id: "")
  end

  def select_days
    find(".dr-settle-checkbox[data-dr-id='#{day1[0].id}']").check
    find(".dr-settle-checkbox[data-dr-id='#{day2[0].id}']").check
  end

  it "settles the selected days into the chosen employee's custody account" do
    select_days
    expect(page).to have_css("#bulk-settle-count", text: "2")
    expect(page).to have_css("#bulk-settle-total", text: /250/)
    expect(page).to have_no_select("payment_method_id")

    select recipient.full_name, from: "bulk-settle-recipient", match: :first
    fill_in "bulk-settle-notes", with: "Supervisor collected the shortfall"

    message = accept_confirm { click_button I18n.t("finance.daily_reconciliations.index.bulk_settle_custody_btn") }
    expect(message).to include(recipient.full_name).and include("250")

    expect(page).to have_text(recipient.full_name)
    expect(account.reload.current_balance).to eq(250)
    expect(RemainingDepositBalance.open.count).to eq(0)
  end

  it "shows an error and records nothing when a selected day was settled meanwhile" do
    select_days
    select recipient.full_name, from: "bulk-settle-recipient", match: :first
    fill_in "bulk-settle-notes", with: "Supervisor collected"

    Finance::RemainingDepositBalanceSettler.new(day2[1].id, actor: actor, amount: 150, notes: "elsewhere").call

    accept_confirm { click_button I18n.t("finance.daily_reconciliations.index.bulk_settle_custody_btn") }

    expect(page).to have_text(I18n.t("finance.daily_reconciliations.errors.bulk_settle.already_settled"))
    expect(CustodyTransaction.count).to eq(0)
    expect(day1[1].reload).to be_open
  end

  context "Receive Cash (receive_shortage_settlement_cash)" do
    let(:actor) do
      user_with("view_daily_reconciliation", "settle_remaining_deposit_balance", "receive_shortage_settlement_cash",
                "view_employee_balances", "manage_employee_balances", first_name: "Sara", last_name: "Finance")
    end
    let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

    it "settles the selected days as received cash with the Cash payment method — no custody credit" do
      visit finance_daily_reconciliations_path(branch_id: "") # cash_pm exists only after the outer visit
      select_days
      choose "bulk-settle-destination-cash"
      expect(page).to have_no_select("bulk-settle-recipient") # custody fields hidden
      expect(page).to have_select("bulk-settle-cash-method", selected: "Cash")
      fill_in "bulk-settle-reference", with: "RC-9"
      # Notes left empty on purpose — the field is optional; the browser must submit.
      expect(page).to have_css("#bulk-settle-notes:not([required])")

      message = accept_confirm { click_button I18n.t("finance.daily_reconciliations.index.bulk_settle_cash_btn") }
      expect(message).to include("Cash").and include("250")

      expect(page).to have_text(I18n.t("finance.daily_reconciliations.bulk_settle_cash_done",
                                       count: 2, amount: "", method: "Cash").split("—").first.strip)
      expect(RemainingDepositBalanceTransaction.settlements.pluck(:payment_method_id).uniq).to eq([ cash_pm.id ])
      expect(RemainingDepositBalanceTransaction.settlements.pluck(:notes).uniq).to eq([ nil ])
      expect(CustodyTransaction.count).to eq(0)
      expect(account.reload.current_balance).to eq(0)
    end
  end
end
