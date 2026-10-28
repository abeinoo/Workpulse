require "rails_helper"

# GET /finance/bank_statement_transactions/:id/manual_match_modal — the
# transaction-side "pick a deposit" list. TillDeposit.not_fully_matched used
# LEFT JOIN + GROUP BY, which PostgreSQL rejected once the controller's
# where(daily_reconciliations: …) made includes eager-load the DR, branch,
# payment-method and user columns (PG::GroupingError on daily_reconciliations.id):
# the modal raised for every transaction.
RSpec.describe "Bank transaction manual match modal", type: :request do
  let(:business)     { create(:business) }
  let(:branch)       { create(:branch, business: business) }
  let(:other_branch) { create(:branch, business: business) }
  let(:cash_pm)      { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)          { Date.new(2026, 10, 20) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:depositor) { create(:user, business: business) }

  def dr_for(branch:, date:)
    DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                opened_at: Time.current, business_date: date)
  end

  def deposit(dr, amount:, **attrs)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: depositor,
                        amount: amount, deposited_at: business.timezone_object.parse("#{dr.business_date} 21:00"), **attrs)
  end

  let(:statement) do
    create(:bank_statement, business: business, branch: branch, statement_from: day - 1, statement_to: day + 1)
  end

  def bank_line(amount:, status: "unexpected")
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: amount,
                                     transaction_date: day, raw_data: {}, status: status)
  end

  def link!(dep, txn)
    DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: txn)
    txn.update!(status: "verified", match_method: "manual")
  end

  def offered_deposit_ids
    Nokogiri::HTML(response.body).css("input[name='till_deposit_id']").map { |i| i["value"].to_i }
  end

  it "renders and offers only eligible deposits, each once", :aggregate_failures do
    dr = dr_for(branch: branch, date: day)
    unmatched = deposit(dr, amount: 6_100)
    partial   = deposit(dr, amount: 11_700)
    link!(partial, bank_line(amount: 7_000))
    link!(partial, bank_line(amount: 2_000)) # two matches — must not duplicate the row
    full = deposit(dr, amount: 500)
    link!(full, bank_line(amount: 500))
    voided = deposit(dr, amount: 6_100, voided_at: Time.current, void_reason: "wrong slip")
    other_branch_dep = deposit(dr_for(branch: other_branch, date: day), amount: 6_100)
    out_of_range     = deposit(dr_for(branch: branch, date: day + 5), amount: 6_100)

    target = bank_line(amount: 6_100)
    sign_in user_with("view_deposit_verification", "verify_deposits", "manual_match_deposits")

    get manual_match_modal_finance_bank_statement_transaction_path(target)

    expect(response).to have_http_status(:ok)
    expect(offered_deposit_ids).to contain_exactly(unmatched.id, partial.id)
    expect(offered_deposit_ids).not_to include(full.id, voided.id, other_branch_dep.id, out_of_range.id)
  end

  it "renders the empty state when no deposit is eligible" do
    target = bank_line(amount: 6_100)
    sign_in user_with("view_deposit_verification", "verify_deposits", "manual_match_deposits")

    get manual_match_modal_finance_bank_statement_transaction_path(target)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(ERB::Util.html_escape(I18n.t("finance.bank_statement_transactions.show.modal_no_deposits")))
  end
end
