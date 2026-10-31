require "rails_helper"

# A bank transaction whose statement was soft-deleted: its page stays readable
# (audit history) with the deletion shown, links back to the statements list
# instead of the hidden statement, and only Unmatch remains — Manual Match and
# Ignore are refused by BankStatementTransactionPolicy.
RSpec.describe "Bank transaction on a deleted statement", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.in_time_zone(business.timezone_object).to_date }

  def user_with(*perms, business: self.business, **attrs)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business, preferred_locale: "en", **attrs).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:reviewer) do
    user_with("view_daily_reconciliation", "view_deposit_verification", "verify_deposits",
              "manual_match_deposits", "import_bank_statement", "delete_import",
              last_name: "O'Conner") # BUG-035: the view HTML-escapes the apostrophe
  end

  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                opened_at: 1.hour.ago, closed_at: Time.current, business_date: day)
  end
  let!(:deposit) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: reviewer,
                        amount: 250, deposited_at: Time.current)
  end
  let(:statement) do
    create(:bank_statement, :pending, business: business, branch: branch,
           statement_from: day - 3, statement_to: day + 3)
  end
  let!(:line) do
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: 250,
                                     transaction_date: day, raw_data: {}, status: "pending")
  end

  def html = Nokogiri::HTML(response.body)

  context "deleted through Deleter (match released)" do
    before do
      Finance::DepositVerification::MatchingEngine.call(statement.id, actor: reviewer)
      Finance::BankStatements::Deleter.call(statement.id, actor: reviewer, notes: "Duplicate upload")
      sign_in reviewer
    end

    it "renders the page with the deletion shown and a working Back link", :aggregate_failures do
      get finance_bank_statement_transaction_path(line)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ERB::Util.html_escape(
        I18n.t("finance.bank_statement_transactions.show.statement_deleted_title", id: statement.id)
      ))
      # The deletion notice names who deleted the statement. Scoped to the notice
      # (the reviewer's name is also in the sidebar); .text decodes the HTML.
      notices = html.css("[role='status']")
      expect(notices.size).to eq(1)
      expect(notices.first.text.squish).to include("by #{reviewer.full_name}.")
      back = html.css(".page-header a").map { |a| a["href"] }
      expect(back).to include(finance_bank_statements_path)
      expect(back).not_to include(finance_bank_statement_path(statement))
      expect(response.body).not_to include(manual_match_modal_finance_bank_statement_transaction_path(line))
      expect(response.body).not_to include(ignore_finance_bank_statement_transaction_path(line))
      # Audit history stays visible.
      expect(response.body).to include(I18n.t("finance.bank_statement_transactions.timeline.released_by_statement_deletion"))
    end

    it "refuses the manual-match modal, a match and an ignore", :aggregate_failures do
      get manual_match_modal_finance_bank_statement_transaction_path(line)
      expect(response).to redirect_to(root_path)

      patch match_finance_bank_statement_transaction_path(line), params: { till_deposit_id: deposit.id, match_notes: "x" }
      expect(response).to redirect_to(root_path)
      expect(line.reload.deposit_matches).to be_empty

      patch ignore_finance_bank_statement_transaction_path(line), params: { ignored_reason: "x" }
      expect(response).to redirect_to(root_path)
      expect(line.reload.status).to eq("unexpected")
    end
  end

  context "legacy state: deleted before deletion released matches" do
    before do
      Finance::DepositVerification::MatchingEngine.call(statement.id, actor: reviewer)
      statement.update_columns(deleted_at: Time.current, deleted_by_id: reviewer.id)
      sign_in reviewer
    end

    it "keeps Unmatch available to remove the stale link, audited", :aggregate_failures do
      get finance_bank_statement_transaction_path(line)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(unmatch_finance_bank_statement_transaction_path(line))

      patch unmatch_finance_bank_statement_transaction_path(line), params: { unmatch_notes: "Statement was deleted" }

      expect(line.reload.deposit_matches).to be_empty
      expect(deposit.reload.deposit_matches).to be_empty
      expect(AuditLog.where(auditable: line, action: "manual_unmatch").count).to eq(1)
    end
  end

  it "does not expose the line to another business" do
    Finance::BankStatements::Deleter.call(statement.id, actor: reviewer)
    other_business = create(:business)
    sign_in user_with("view_deposit_verification", "verify_deposits", "manual_match_deposits", business: other_business)

    get finance_bank_statement_transaction_path(line)

    expect(response).to have_http_status(:not_found)
  end
end
