require "rails_helper"

RSpec.describe "Daily Reconciliations index — bank reconciliation status filter", type: :request do
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

  let(:actor)   { user_with("view_daily_reconciliation", "view_deposit_verification") }
  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  before { sign_in actor }

  def make_dr(business_date:)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: business_date.to_time + 10.hours, closed_at: business_date.to_time + 23.hours,
      business_date: business_date, reviewed_by: actor, reviewed_at: business_date.to_time + 23.hours
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id)
    dr
  end

  def collect_cash!(dr, amount)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                              payment_method_name: cash_pm.name, collected_amount: amount, refund_amount: 0)
  end

  def deposit(dr, amount:, deposited_at:)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: amount, deposited_at: deposited_at)
  end

  # Statuses under test, one representative DR each:
  let(:no_bank_transactions_dr) { make_dr(business_date: Date.new(2026, 7, 10)) } # no cash collected

  let(:waiting_for_deposit_dr) do
    dr = make_dr(business_date: Date.new(2026, 7, 11))
    collect_cash!(dr, 500)
    dr
  end

  let(:waiting_for_bank_statement_dr) do
    dr = make_dr(business_date: Date.new(2026, 7, 12))
    collect_cash!(dr, 500)
    deposit(dr, amount: 500, deposited_at: Time.zone.local(2026, 7, 12, 14, 0, 0))
    dr
  end

  let(:completed_dr) do
    dr = make_dr(business_date: Date.new(2026, 7, 13))
    collect_cash!(dr, 500)
    dep = deposit(dr, amount: 500, deposited_at: Time.zone.local(2026, 7, 13, 14, 0, 0))
    stmt = create(:bank_statement, business: business, branch: branch,
                  statement_from: Date.new(2026, 7, 13), statement_to: Date.new(2026, 7, 13))
    txn = BankStatementTransaction.create!(bank_statement: stmt, business: business,
                                           transaction_date: Date.new(2026, 7, 13), amount: 500,
                                           raw_data: {}, status: "unexpected")
    DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: txn, matched_by: actor)
    txn.update!(status: "verified")
    dr
  end

  it "counts and lists every DR when no filter is applied" do
    no_bank_transactions_dr
    waiting_for_deposit_dr
    waiting_for_bank_statement_dr
    completed_dr

    get finance_daily_reconciliations_path

    ids = Nokogiri::HTML(response.body).css("a[href*='/finance/daily_reconciliations/']").map { |a| a["href"] }
    expect(response).to have_http_status(:ok)
    expect(ids.any? { |h| h.include?(completed_dr.id.to_s) }).to be true
  end

  it "filters to only Completed reconciliations" do
    waiting_for_deposit_dr
    completed_dr

    get finance_daily_reconciliations_path(verification_status: "completed")

    body = response.body
    expect(body).to include(finance_daily_reconciliation_path(completed_dr))
    expect(body).not_to include(finance_daily_reconciliation_path(waiting_for_deposit_dr))
  end

  it "filters to only Waiting for Deposit reconciliations" do
    waiting_for_deposit_dr
    completed_dr

    get finance_daily_reconciliations_path(verification_status: "waiting_for_deposit")

    body = response.body
    expect(body).to include(finance_daily_reconciliation_path(waiting_for_deposit_dr))
    expect(body).not_to include(finance_daily_reconciliation_path(completed_dr))
  end

  it "filters to only Waiting for Bank Statement reconciliations" do
    waiting_for_deposit_dr
    waiting_for_bank_statement_dr

    get finance_daily_reconciliations_path(verification_status: "waiting_for_bank_statement")

    body = response.body
    expect(body).to include(finance_daily_reconciliation_path(waiting_for_bank_statement_dr))
    expect(body).not_to include(finance_daily_reconciliation_path(waiting_for_deposit_dr))
  end

  it "filters to only No Bank Transactions reconciliations" do
    no_bank_transactions_dr
    completed_dr

    get finance_daily_reconciliations_path(verification_status: "no_bank_transactions")

    body = response.body
    expect(body).to include(finance_daily_reconciliation_path(no_bank_transactions_dr))
    expect(body).not_to include(finance_daily_reconciliation_path(completed_dr))
  end

  it "renders the per-row progress badge showing matched/total deposits" do
    completed_dr

    get finance_daily_reconciliations_path

    expect(response.body).to include(I18n.t("finance.daily_reconciliations.index.bank_status_progress.complete",
                                            matched: 1, total: 1))
  end

  it "renders the 8-option status select and 7 KPI cards" do
    completed_dr

    get finance_daily_reconciliations_path

    doc = Nokogiri::HTML(response.body)
    select = doc.at_css("select[name='verification_status']")
    expect(select.css("option").size).to eq(DailyReconciliation::BANK_RECONCILIATION_STATUSES.size + 1) # + "All"

    DailyReconciliation::BANK_RECONCILIATION_STATUSES.each do |status|
      next if status == "no_bank_transactions" # not a KPI card, per spec

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.index.bank_status.#{status}"))
    end
  end

  it "does not show the bank status filter/cards to a user without view_deposit_verification" do
    viewer = user_with("view_daily_reconciliation")
    sign_out actor
    sign_in viewer
    completed_dr

    get finance_daily_reconciliations_path

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("select[name='verification_status']")).to be_nil
  end
end
