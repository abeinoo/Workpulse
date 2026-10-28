require "rails_helper"

# DR show page bank summary: "matched" / "Confirmed by Bank" count only a
# verified link on a live statement. A link needing re-verification, or left
# on a deleted statement, is neither confirmed nor unmatched — it gets its own
# badge, an exception row and a "Review bank match" action, never silence.
RSpec.describe "Daily Reconciliation bank summary — verified vs linked-but-unconfirmed", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.in_time_zone(business.timezone_object).to_date }

  let(:viewer) do
    perms = %w[view_daily_reconciliation view_deposit_verification verify_deposits manual_match_deposits]
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms,
                                             permission_scopes: perms.index_with { "business_wide" })
    create(:user, business: business, preferred_locale: "en").tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                opened_at: 1.hour.ago, closed_at: Time.current, business_date: day)
  end
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 11_450, refund_amount: 0)
  end
  let!(:deposit) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: viewer,
                        amount: 11_450, deposited_at: Time.current)
  end
  let(:statement) do
    create(:bank_statement, business: business, branch: branch, statement_from: day - 3, statement_to: day + 3)
  end

  def linked_line!(status:)
    line = BankStatementTransaction.create!(bank_statement: statement, business: business, amount: 11_450,
                                            transaction_date: day, raw_data: {}, status: status,
                                            match_method: "auto_amount_date", match_confidence: 90)
    DepositMatch.create_for!(till_deposit: deposit, bank_statement_transaction: line)
    line
  end

  def bank_t(key, **args) = I18n.t("finance.daily_reconciliations.show.sections.bank.#{key}", **args)
  def exc_t(key, **args)  = I18n.t("finance.daily_reconciliations.show.sections.exceptions.#{key}", **args)
  def money(amount)       = ApplicationController.helpers.number_with_precision(amount, precision: 2, delimiter: ",")

  def show!
    sign_in viewer
    get finance_daily_reconciliation_path(dr)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def summary(html) = html.css("#bank-deposits .recon-formula-row .recon-formula-row__value").map { |n| n.text.strip }
  def badges(html)  = html.css("#bank-deposits .badge").map { |n| n.text.squish }
  def reload_dr     = DailyReconciliation.includes(till_deposits: [ { deposit_matches: { bank_statement_transaction: :bank_statement } },
                                                                    { bank_statement_transactions: :bank_statement } ]).find(dr.id)

  it "counts a verified link on a live statement as matched and confirmed", :aggregate_failures do
    linked_line!(status: "verified")

    html = show!

    expect(summary(html)[1]).to end_with(money(11_450))
    expect(badges(html)).to include(bank_t(:matched, count: 1))
    expect(response.body).not_to include(bank_t(:review_match_action))
    expect(reload_dr.total_matched_amount).to eq(11_450)
    expect(dr.reload.total_matched_amount).to eq(11_450) # same figure without preloads
  end

  it "keeps a needs_reverification link out of the confirmed figures but visible for review", :aggregate_failures do
    line = linked_line!(status: "needs_reverification")

    html = show!

    expect(summary(html)[1]).to end_with(money(0))
    expect(badges(html)).to include(bank_t(:matched, count: 0))
    expect(badges(html)).to include(a_string_matching(/1 match needs re-verification \(.*#{Regexp.escape(money(11_450))}\)/))
    expect(badges(html).join).not_to match(/missing|not imported/i) # linked, so not unmatched
    expect(response.body).to include(exc_t(:bank_needs_reverification))
    expect(html.css("#bank-deposits a").map { |a| a["href"] }).to include(finance_bank_statement_transaction_path(line))
    expect(reload_dr.total_matched_amount).to eq(0)
    expect(reload_dr.bank_reconciliation_status).to eq("needs_review")
  end

  it "flags a link left on a deleted statement for cleanup instead of counting or hiding it", :aggregate_failures do
    line = linked_line!(status: "verified") # the line still reads "verified"
    statement.update_columns(deleted_at: Time.current)

    html = show!

    expect(summary(html)[1]).to end_with(money(0))
    expect(badges(html)).to include(bank_t(:matched, count: 0))
    expect(badges(html)).to include(a_string_matching(/1 match on a deleted statement/))
    expect(response.body).to include(ERB::Util.html_escape(exc_t(:bank_stale_link, id: statement.id)))
    expect(response.body.scan(finance_bank_statement_transaction_path(line)).size).to be >= 2 # review action + exception
    expect(response.body).not_to include(finance_bank_statement_path(statement))            # no link to a 404
    expect(reload_dr.total_matched_amount).to eq(0)
    expect(reload_dr.bank_reconciliation_status).to eq("needs_review")
  end

  it "lists a transaction in one exception category only" do
    linked_line!(status: "needs_reverification")
    statement.update_columns(deleted_at: Time.current)

    show!

    expect(response.body).to include(ERB::Util.html_escape(exc_t(:bank_stale_link, id: statement.id)))
    expect(response.body).not_to include(exc_t(:bank_needs_reverification))
  end

  it "leaves a genuinely unmatched deposit as missing from the bank, with no review action", :aggregate_failures do
    statement # a completed statement covers the day

    html = show!

    expect(badges(html)).to include(bank_t(:missing, count: 1))
    expect(response.body).not_to include(bank_t(:review_match_action))
    expect(reload_dr.total_matched_amount).to eq(0)
  end

  it "never shows a deposit linked only to a deleted statement as verified on Deposit Verification" do
    linked_line!(status: "verified")
    statement.update_columns(deleted_at: Time.current)
    sign_in viewer

    get finance_deposit_verifications_path(tab: "all")

    expect(response.body).to include(I18n.t("finance.deposit_verifications.statuses.linked_to_deleted_statement"))
  end
end
