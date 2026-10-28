require "rails_helper"

# Deposit Verification's status badge for a deposit linked to several bank
# lines: a line needing re-verification outranks the aggregate "Fully Matched"
# (the amounts still add up, but the bank no longer confirms the deposit).
RSpec.describe "Deposit Verification deposit badge with several linked lines", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.in_time_zone(business.timezone_object).to_date }

  let(:viewer) do
    perms = %w[view_deposit_verification verify_deposits manual_match_deposits]
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms,
                                             permission_scopes: perms.index_with { "business_wide" })
    create(:user, business: business, preferred_locale: "en").tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                opened_at: 1.hour.ago, closed_at: Time.current, business_date: day)
  end
  let!(:deposit) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: viewer,
                        amount: 11_450, deposited_at: Time.current)
  end
  let(:statement) do
    create(:bank_statement, business: business, branch: branch, statement_from: day - 3, statement_to: day + 3)
  end

  def linked_line!(amount, status:)
    line = BankStatementTransaction.create!(bank_statement: statement, business: business, amount: amount,
                                            transaction_date: day, raw_data: {}, status: status)
    DepositMatch.create_for!(till_deposit: deposit, bank_statement_transaction: line)
    line
  end

  def deposit_badges
    sign_in viewer
    get finance_deposit_verifications_path(tab: "all")
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body).css(".table-container tbody tr td:first-child .badge").map { |n| n.text.squish }
  end

  def fully_matched = I18n.t("finance.deposit_verifications.match_statuses.fully_matched", count: 2)
  def reverify      = I18n.t("finance.bank_statement_transactions.statuses.needs_reverification")

  it "shows re-verification instead of Fully Matched when one linked line needs it", :aggregate_failures do
    linked_line!(5_000, status: "verified")
    linked_line!(6_450, status: "needs_reverification")
    expect(deposit.match_status).to eq(:fully_matched) # the amounts alone would read as fully matched

    badges = deposit_badges

    expect(badges).to include(reverify)
    expect(badges).not_to include(fully_matched)
  end

  it "still shows Fully Matched when every linked line is verified" do
    linked_line!(5_000, status: "verified")
    linked_line!(6_450, status: "verified")

    expect(deposit_badges).to include(fully_matched)
  end

  it "still flags a deposit linked to a deleted statement ahead of re-verification", :aggregate_failures do
    linked_line!(5_000, status: "verified")
    linked_line!(6_450, status: "needs_reverification")
    statement.update_columns(deleted_at: Time.current)

    badges = deposit_badges

    expect(badges).to include(I18n.t("finance.deposit_verifications.statuses.linked_to_deleted_statement"))
    expect(badges).not_to include(fully_matched, reverify)
  end
end
