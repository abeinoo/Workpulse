require "rails_helper"

# Regression coverage for the Cash Reconciliation "remaining difference"
# calculation: open ATM Deposit Disputes (BankDispute kind: atm_deposit_failure)
# must be treated as already-accounted-for cash, the same way DailyReconciliation
# #pending_deposit_amount already treats them for the Record Deposit dialog.
#
# Formula under test (Finance::DailyReconciliationsController#build_show_summary_aggregates):
#   @cash_difference = total_deposited + open_atm_dispute_amount - expected_cash
# (negative => still short; zero => balanced; positive => over-deposited)
RSpec.describe "Finance::DailyReconciliations show — cash reconciliation vs bank disputes", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer) { user_with("view_daily_reconciliation", "view_session_totals") }

  def build_dr(expected_amount:)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: viewer.id)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: expected_amount, refund_amount: 0)
    dr
  end

  def add_deposit(dr, amount)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: viewer,
                        amount: amount, deposited_at: Time.current)
  end

  def add_atm_dispute(dr, amount:, status: "new")
    BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: viewer,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: amount, status: status, bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )
  end

  EXPECTED_LABEL  = "finance.daily_reconciliations.show.sections.cash.expected_cash"
  DISPUTE_LABEL   = "finance.daily_reconciliations.show.sections.cash.bank_disputes"
  DEPOSITED_LABEL = "finance.daily_reconciliations.show.sections.cash.actual_deposited"
  DIFFERENCE_LABEL = "finance.daily_reconciliations.show.sections.cash.difference"

  # Maps each visible "<label> <value>" row inside #cash-reconciliation's
  # formula block to its raw text value, keyed by the row's label text.
  def cash_rows
    doc = Nokogiri::HTML(response.body)
    section = doc.at_css("#cash-reconciliation")
    section.css(".recon-formula-row").each_with_object({}) do |row, h|
      spans = row.css("span")
      next if spans.size < 2
      h[spans[0].text.strip] = spans[1].text.strip
    end
  end

  def parse_amount(text)
    return nil if text.nil? || text == "—"
    text.gsub(/[^\d.\-]/, "").to_d
  end

  before { sign_in viewer }

  it "case 1: expected 12,815 / dispute 12,750 / deposited 0 -> remaining 65" do
    dr = build_dr(expected_amount: 12_815)
    add_atm_dispute(dr, amount: 12_750)

    get finance_daily_reconciliation_path(dr)
    expect(response).to have_http_status(:ok)

    rows = cash_rows
    expect(parse_amount(rows[I18n.t(EXPECTED_LABEL)])).to eq(12_815.to_d)
    expect(parse_amount(rows[I18n.t(DISPUTE_LABEL)])).to eq(12_750.to_d)
    expect(parse_amount(rows[I18n.t(DEPOSITED_LABEL)])).to eq(0.to_d)
    expect(parse_amount(rows[I18n.t(DIFFERENCE_LABEL)])).to eq(-65.to_d)
  end

  it "case 2: expected 12,815 / dispute 0 / deposited 12,815 -> balanced (no remaining)" do
    dr = build_dr(expected_amount: 12_815)
    add_deposit(dr, 12_815)

    get finance_daily_reconciliation_path(dr)

    rows = cash_rows
    expect(rows).not_to have_key(I18n.t(DISPUTE_LABEL))
    expect(rows[I18n.t(DIFFERENCE_LABEL)]).to eq("—")
  end

  it "case 3: expected 12,815 / dispute 12,750 / deposited 65 -> balanced" do
    dr = build_dr(expected_amount: 12_815)
    add_atm_dispute(dr, amount: 12_750)
    add_deposit(dr, 65)

    get finance_daily_reconciliation_path(dr)

    rows = cash_rows
    expect(parse_amount(rows[I18n.t(DISPUTE_LABEL)])).to eq(12_750.to_d)
    expect(rows[I18n.t(DIFFERENCE_LABEL)]).to eq("—")
  end

  it "case 4: expected 12,815 / dispute 10,000 / deposited 2,000 -> remaining 815" do
    dr = build_dr(expected_amount: 12_815)
    add_atm_dispute(dr, amount: 10_000)
    add_deposit(dr, 2_000)

    get finance_daily_reconciliation_path(dr)

    rows = cash_rows
    expect(parse_amount(rows[I18n.t(DIFFERENCE_LABEL)])).to eq(-815.to_d)
  end

  it "case 5: multiple bank disputes (10,000 + 2,000) / deposited 500 -> remaining 315" do
    dr = build_dr(expected_amount: 12_815)
    add_atm_dispute(dr, amount: 10_000)
    add_atm_dispute(dr, amount: 2_000)
    add_deposit(dr, 500)

    get finance_daily_reconciliation_path(dr)

    rows = cash_rows
    expect(parse_amount(rows[I18n.t(DISPUTE_LABEL)])).to eq(12_000.to_d)
    expect(parse_amount(rows[I18n.t(DIFFERENCE_LABEL)])).to eq(-315.to_d)
  end

  it "case 6: multiple deposits and multiple disputes combine to a balanced day" do
    dr = build_dr(expected_amount: 12_815)
    add_atm_dispute(dr, amount: 5_000)
    add_atm_dispute(dr, amount: 5_000)
    add_deposit(dr, 2_000)
    add_deposit(dr, 815)

    get finance_daily_reconciliation_path(dr)

    rows = cash_rows
    expect(parse_amount(rows[I18n.t(DISPUTE_LABEL)])).to eq(10_000.to_d)
    expect(rows[I18n.t(DIFFERENCE_LABEL)]).to eq("—")
  end

  it "case 7: a rejected (resolved) dispute must NOT reduce the remaining amount" do
    dr = build_dr(expected_amount: 12_815)
    add_atm_dispute(dr, amount: 12_750, status: "rejected")

    get finance_daily_reconciliation_path(dr)

    rows = cash_rows
    expect(rows).not_to have_key(I18n.t(DISPUTE_LABEL))
    expect(parse_amount(rows[I18n.t(DIFFERENCE_LABEL)])).to eq(-12_815.to_d)
  end

  it "case 8: a missing_from_bank dispute (anchored on an existing deposit) is not double-counted" do
    dr = build_dr(expected_amount: 12_815)
    deposit = add_deposit(dr, 12_815)
    BankDispute.create!(
      till_deposit: deposit, business: business, branch: branch, opened_by: viewer,
      opened_at: Time.current, transaction_date: Date.current, kind: "missing_from_bank",
      amount: 12_815, status: "new", bank_name: "NBE", terminal_id: "ATM-1"
    )

    get finance_daily_reconciliation_path(dr)

    rows = cash_rows
    # missing_from_bank's amount is already inside "actual deposited" — it must
    # not also appear as a bank-disputes row, or it would be subtracted twice.
    expect(rows).not_to have_key(I18n.t(DISPUTE_LABEL))
    expect(rows[I18n.t(DIFFERENCE_LABEL)]).to eq("—")
  end

  it "case 9: disputes are scoped per branch/reconciliation — another branch's dispute is not counted" do
    other_branch = create(:branch, business: business)
    other_dr = DailyReconciliation.create!(
      branch: other_branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
    TillSession.create!(daily_reconciliation: other_dr, depositor_id: viewer.id)
    add_atm_dispute(other_dr, amount: 999)

    dr = build_dr(expected_amount: 12_815)
    add_atm_dispute(dr, amount: 12_750)

    get finance_daily_reconciliation_path(dr)

    rows = cash_rows
    expect(parse_amount(rows[I18n.t(DISPUTE_LABEL)])).to eq(12_750.to_d)
    expect(parse_amount(rows[I18n.t(DIFFERENCE_LABEL)])).to eq(-65.to_d)
  end

  it "case 10: no bank disputes at all -> row is absent and behaviour is unchanged" do
    dr = build_dr(expected_amount: 12_815)
    add_deposit(dr, 12_815)

    get finance_daily_reconciliation_path(dr)

    rows = cash_rows
    expect(rows).not_to have_key(I18n.t(DISPUTE_LABEL))
    expect(rows[I18n.t(DIFFERENCE_LABEL)]).to eq("—")
  end
end
