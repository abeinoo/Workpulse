require "rails_helper"

# DELETE /finance/bank_statements/:id — soft-deletes through
# Finance::BankStatements::Deleter, releasing the deposit matches held by the
# statement's transactions, and the released lines stay out of the DR page,
# Deposit Verification and every matching flow.
RSpec.describe "Bank statement deletion", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.in_time_zone(business.timezone_object).to_date }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business, preferred_locale: "en").tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:reviewer) do
    user_with("view_daily_reconciliation", "view_deposit_verification", "verify_deposits",
              "manual_match_deposits", "import_bank_statement", "delete_import")
  end

  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                opened_at: 1.hour.ago, closed_at: Time.current, business_date: day)
  end

  let!(:deposit) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: reviewer,
                        amount: 6_100, deposited_at: Time.current)
  end

  def statement_with_line!
    st = create(:bank_statement, :pending, business: business, branch: branch,
                statement_from: day - 3, statement_to: day + 3)
    line = BankStatementTransaction.create!(bank_statement: st, business: business, amount: 6_100,
                                            transaction_date: day, raw_data: {}, status: "pending")
    Finance::DepositVerification::MatchingEngine.call(st.id, actor: reviewer)
    [ st, line ]
  end

  it "releases the statement's matches and keeps its released lines out of the DR page and Deposit Verification",
     :aggregate_failures do
    st, line = statement_with_line!
    expect(line.reload.matched_till_deposit).to eq(deposit)
    sign_in reviewer

    delete finance_bank_statement_path(st), params: { deletion_notes: "Duplicate upload" }

    expect(response).to redirect_to(finance_bank_statements_path)
    expect(st.reload).to be_deleted
    expect(line.reload.deposit_matches).to be_empty
    expect(AuditLog.where(auditable: line, action: "released_by_statement_deletion").count).to eq(1)

    get finance_daily_reconciliation_path(dr)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(finance_bank_statement_transaction_path(line))

    get finance_deposit_verifications_path(tab: "unexpected")
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(finance_bank_statement_transaction_path(line))
  end

  it "refuses a second deletion without changing anything" do
    st, = statement_with_line!
    sign_in reviewer
    delete finance_bank_statement_path(st)

    expect { Finance::BankStatements::Deleter.call(st.id, actor: reviewer) }
      .not_to(change { AuditLog.count })
  end

  it "is still forbidden without delete_import" do
    st, line = statement_with_line!
    sign_in user_with("view_deposit_verification", "import_bank_statement")

    delete finance_bank_statement_path(st)

    expect(st.reload).not_to be_deleted
    expect(line.reload.matched_till_deposit).to eq(deposit)
  end

  it "shows the transaction page's review candidates with their current link" do
    old_st, old_line = statement_with_line!
    reimport = create(:bank_statement, :pending, business: business, branch: branch,
                      statement_from: day - 3, statement_to: day + 3)
    new_line = BankStatementTransaction.create!(bank_statement: reimport, business: business, amount: 6_100,
                                                transaction_date: day, raw_data: {}, status: "pending")
    Finance::DepositVerification::MatchingEngine.call(reimport.id, actor: reviewer)
    sign_in reviewer

    get finance_bank_statement_transaction_path(new_line)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("finance.bank_statement_transactions.statuses.needs_manual_review"))
    expect(response.body).to include(I18n.t("finance.bank_statement_transactions.show.candidates_linked_to",
                                            transaction_id: old_line.id, statement_id: old_st.id))
    expect(response.body).not_to include(I18n.t("finance.bank_statement_transactions.statuses.unexpected"))
  end
end
