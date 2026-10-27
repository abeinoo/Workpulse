require "rails_helper"

# End-to-end lifecycle of one bank transaction across a deposit void:
#   import (auto-match) → void the matched deposit (match released) →
#   record a replacement → manual match → reload pages.
# At every completed state the statement's persisted counters must agree with
# the underlying transaction/match rows, and the DR and statement pages must
# show figures derived from those same rows.
RSpec.describe "Bank match lifecycle across a deposit void — counter consistency", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:tz)       { business.timezone_object }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business, preferred_locale: "en")
      .tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current)
  end

  let(:depositor) { user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit") }
  let(:reviewer) do
    user_with("view_daily_reconciliation", "view_deposit_verification", "verify_deposits",
              "manual_match_deposits", "void_till_deposit", "import_bank_statement")
  end

  before do
    TillSession.create!(daily_reconciliation: dr, depositor_id: depositor.id)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: cash_pm.name,
                              collected_amount: 6_100, refund_amount: 0)
  end

  def record_deposit!
    result = Finance::TillDepositRecorder.new(
      dr.id, actor: depositor,
      params: { payment_method_id: cash_pm.id, amount: "6100.00", deposited_at: Time.current.to_s }
    ).call
    expect(result).to be_ok
    result.deposit
  end

  def import_statement!
    day = Time.current.in_time_zone(tz).to_date
    statement = create(:bank_statement, :pending, business: business, branch: branch,
                       statement_from: day, statement_to: day)
    csv = "Value Date,Credit Amount,Reference\n#{day.iso8601},6100.00,\n#{day.iso8601},250.00,\n"
    statement.file.attach(io: StringIO.new(csv), filename: statement.file_name, content_type: "text/csv")
    expect(Finance::BankStatements::Importer.call(statement.id, actor: reviewer)).to be_ok
    statement.reload
  end

  # Persisted counters vs. the rows they summarise.
  def expect_counters_consistent!(statement)
    statement.reload
    txns = statement.bank_statement_transactions
    matched   = txns.where.associated(:deposit_matches).distinct.count
    unmatched = txns.where.missing(:deposit_matches).where.not(status: "ignored").count

    expect(statement.matched_rows).to eq(matched)
    expect(statement.unmatched_rows).to eq(unmatched)
    expect(statement.total_rows).to eq(txns.count)
    # A transaction backs at most one deposit; verified ⇔ linked.
    expect(DepositMatch.where(bank_statement_transaction_id: txns.select(:id)).count).to eq(matched)
    expect(txns.verified.where.missing(:deposit_matches)).to be_empty
    # A voided deposit never keeps a link.
    expect(DepositMatch.joins(:till_deposit).where.not(till_deposits: { voided_at: nil })).to be_empty
  end

  def dr_bank_figures
    get finance_daily_reconciliation_path(dr)
    expect(response).to have_http_status(:ok)
    rows = Nokogiri::HTML(response.body).css("#bank-deposits .recon-formula-row .recon-formula-row__value")
    expected, imported, _difference = rows.map { |r| r.text.strip }
    { expected: expected, imported: imported, body: response.body }
  end

  def money(amount) = ApplicationController.helpers.number_with_precision(amount, precision: 2, delimiter: ",")
  def matched_badge(count) = I18n.t("finance.daily_reconciliations.show.sections.bank.matched", count: count)

  it "keeps counters, statuses and page figures in agreement at every step", :aggregate_failures do
    sign_in reviewer

    # 1–2. Import with the deposit already recorded → auto-matched.
    original  = record_deposit!
    statement = import_statement!
    bank_line = statement.bank_statement_transactions.find_by!(amount: 6_100)
    expect(bank_line.status).to eq("verified")
    expect(bank_line.matched_till_deposit).to eq(original)
    expect([ statement.matched_rows, statement.unmatched_rows ]).to eq([ 1, 1 ])
    expect_counters_consistent!(statement)
    figures = dr_bank_figures
    expect(figures[:expected]).to end_with(money(6_100))
    expect(figures[:imported]).to end_with(money(6_100))
    expect(figures[:body]).to include(matched_badge(1))

    # 3–4. Void the matched deposit (as the DR page button does) → match released.
    patch void_till_deposit_path(original), params: { void_reason: "Wrong slip" }
    expect(original.reload).to be_voided
    expect(bank_line.reload.status).to eq("unexpected")
    expect(bank_line.matched_till_deposit).to be_nil
    expect([ statement.reload.matched_rows, statement.unmatched_rows ]).to eq([ 0, 2 ])
    expect_counters_consistent!(statement)
    expect(AuditLog.where(auditable: bank_line, action: "released_by_deposit_void").count).to eq(1)
    expect(AuditLog.where(auditable: original, action: "void").count).to eq(1)
    expect(dr.reload.state).to eq("closed") # last active deposit voided

    # 5. Replacement recorded normally, never auto-matched; then manual match.
    replacement = record_deposit!
    expect(bank_line.reload.matched_till_deposit).to be_nil
    figures = dr_bank_figures
    expect(figures[:imported]).to end_with(money(0))
    expect(figures[:body]).to include(matched_badge(0))
    expect(figures[:body]).to include(manual_match_modal_finance_bank_statement_transaction_path(bank_line))

    patch manual_match_till_deposit_path(replacement),
          params: { bank_statement_transaction_ids: [ bank_line.id ], match_notes: "Re-deposit after void" }
    expect(bank_line.reload.matched_till_deposit).to eq(replacement)
    expect(bank_line.status).to eq("verified")
    expect([ statement.reload.matched_rows, statement.unmatched_rows ]).to eq([ 1, 1 ])
    expect_counters_consistent!(statement)

    # 6. Reload both pages.
    figures = dr_bank_figures
    expect(figures[:expected]).to end_with(money(6_100))
    expect(figures[:imported]).to end_with(money(6_100))
    expect(figures[:body]).to include(matched_badge(1))

    get finance_bank_statement_path(statement)
    expect(response).to have_http_status(:ok)
    get finance_bank_statements_path
    expect(response).to have_http_status(:ok)
    expect(statement.reload.verification_rate).to eq(50.0)

    # A rematch recomputes counters from rows — it must land on the same values.
    Finance::DepositVerification::MatchingEngine.call(statement.id, actor: reviewer, rematch: true)
    expect([ statement.reload.matched_rows, statement.unmatched_rows ]).to eq([ 1, 1 ])
    expect(bank_line.reload.matched_till_deposit).to eq(replacement)
    expect_counters_consistent!(statement)
  end
end
