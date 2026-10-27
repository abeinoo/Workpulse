require "rails_helper"

RSpec.describe "Deposit Verification bulk ignore", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:other_branch) { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:day)      { Time.current.in_time_zone(business.timezone_object).to_date }

  def user_with(*perms, business: self.business, scope: "business_wide")
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { scope }
    )
    create(:user, business: business, preferred_locale: "en").tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:reviewer) { user_with("view_deposit_verification", "verify_deposits", "manual_match_deposits") }

  def statement_for(branch)
    create(:bank_statement, :pending, business: business, branch: branch, statement_from: day - 3, statement_to: day + 3)
  end

  let(:statement) { statement_for(branch) }

  def line!(amount, status: "unexpected", statement: self.statement)
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: amount,
                                     transaction_date: day, raw_data: {}, status: status)
  end

  def matched_line!(amount)
    dr  = DailyReconciliation.create!(branch: branch, business: business, state: "deposited",
                                      opened_at: 1.hour.ago, business_date: day)
    dep = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: reviewer,
                              amount: amount, deposited_at: Time.current)
    line = line!(amount, status: "amount_mismatch")
    DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: line)
    line
  end

  def html = Nokogiri::HTML(response.body)
  def row_box(line) = html.at_css(".dv-bulk-check-row[value='#{line.id}']")

  describe "the selection on the page" do
    it "offers a checkbox only for unlinked lines, with the reason on linked ones", :aggregate_failures do
      free    = line!(10, status: "amount_mismatch")
      matched = matched_line!(250)
      sign_in reviewer

      get finance_deposit_verifications_path(tab: "mismatches")

      expect(response).to have_http_status(:ok)
      expect(html.at_css(".dv-bulk-check-all")).to be_present
      expect(row_box(free)["disabled"]).to be_nil
      expect(row_box(matched)["disabled"]).to be_present
      expect(row_box(matched)["title"]).to eq(I18n.t("finance.deposit_verifications.bulk_ignore.ineligible_matched"))
      expect(response.body).to include(I18n.t("finance.deposit_verifications.bulk_ignore.button"))
    end

    it "offers 'all matching' only when eligible lines exceed the page, with the server's count" do
      31.times { |i| line!(100 + i) } # DEFAULT_PER_PAGE is 30
      sign_in reviewer

      get finance_deposit_verifications_path(tab: "unexpected")

      expect(html.css(".dv-bulk-check-row:not([disabled])").size).to eq(30)
      expect(response.body).to include(I18n.t("finance.deposit_verifications.bulk_ignore.select_all_matching", count: 31))
    end

    it "renders the Arabic bulk action labels for an Arabic user" do
      line!(10)
      arabic = user_with("view_deposit_verification", "verify_deposits", "manual_match_deposits")
      arabic.update!(preferred_locale: "ar")
      sign_in arabic

      get finance_deposit_verifications_path(tab: "unexpected")

      expect(response.body).to include("تجاهل المحدد")
      expect(response.body).to include(I18n.t("finance.deposit_verifications.bulk_ignore.modal_title", locale: :ar))
      expect(html.at_css("html")["dir"]).to eq("rtl")
    end

    it "shows no selection to a viewer without manual_match_deposits" do
      line!(10)
      sign_in user_with("view_deposit_verification")

      get finance_deposit_verifications_path(tab: "unexpected")

      expect(response).to have_http_status(:ok)
      expect(html.at_css(".dv-bulk-check-row")).to be_nil
    end
  end

  describe "POST bulk_ignore" do
    it "ignores the selected lines, keeps the filters, and updates the counters", :aggregate_failures do
      a = line!(10)
      b = line!(20)
      keep = line!(30)
      sign_in reviewer
      get finance_deposit_verifications_path(tab: "unexpected")
      unexpected_before = html.text

      post bulk_ignore_finance_deposit_verifications_path,
           params: { tab: "unexpected", branch_id: branch.id, from: (day - 3).to_s, to: (day + 3).to_s,
                     transaction_ids: [ a.id, b.id ], reason: "Old bank fees" }

      expect(response).to redirect_to(finance_deposit_verifications_path(tab: "unexpected", branch_id: branch.id,
                                                                         from: (day - 3).to_s, to: (day + 3).to_s))
      expect(flash[:notice]).to eq(I18n.t("finance.deposit_verifications.bulk_ignore.done", count: 2))
      expect([ a, b ].map { |t| t.reload.status }).to eq(%w[ignored ignored])
      expect(keep.reload.status).to eq("unexpected")
      expect(AuditLog.where(action: "ignored", actor_id: reviewer.id).count).to eq(2)

      follow_redirect!
      expect(html.css(".dv-bulk-check-row").map { |c| c["value"].to_i }).to eq([ keep.id ])
      expect(unexpected_before).not_to eq(html.text)
      expect(controller.instance_variable_get(:@stats)[:unexpected]).to eq(1)
    end

    it "ignores every eligible line matching the filters across pages when the count still agrees" do
      lines = Array.new(31) { |i| line!(100 + i) }
      elsewhere = line!(999, statement: statement_for(other_branch))
      sign_in reviewer

      post bulk_ignore_finance_deposit_verifications_path,
           params: { tab: "unexpected", branch_id: branch.id, selection: "all_matching",
                     expected_count: 31, reason: "Pre go-live noise" }

      expect(flash[:notice]).to eq(I18n.t("finance.deposit_verifications.bulk_ignore.done", count: 31))
      expect(lines.map { |t| t.reload.status }.uniq).to eq([ "ignored" ])
      expect(elsewhere.reload.status).to eq("unexpected") # outside the branch filter
    end

    it "refuses 'all matching' when the matching set changed since it was shown" do
      2.times { |i| line!(100 + i) }
      sign_in reviewer

      post bulk_ignore_finance_deposit_verifications_path,
           params: { tab: "unexpected", selection: "all_matching", expected_count: 3, reason: "x" }

      expect(flash[:alert]).to eq(I18n.t("finance.bank_statements.errors.bulk_ignore_selection_changed", count: 2))
      expect(BankStatementTransaction.where(status: "ignored")).to be_empty
    end

    it "refuses the batch when it holds a linked line, changing nothing", :aggregate_failures do
      free    = line!(10, status: "amount_mismatch")
      matched = matched_line!(250)
      sign_in reviewer

      post bulk_ignore_finance_deposit_verifications_path,
           params: { tab: "mismatches", transaction_ids: [ free.id, matched.id ], reason: "x" }

      expect(flash[:alert]).to include("##{matched.id}")
      expect(free.reload.status).to eq("amount_mismatch")
      expect(matched.reload.deposit_matches.count).to eq(1)
    end

    it "requires a reason" do
      line = line!(10)
      sign_in reviewer

      post bulk_ignore_finance_deposit_verifications_path,
           params: { tab: "unexpected", transaction_ids: [ line.id ], reason: "" }

      expect(flash[:alert]).to eq(I18n.t("finance.bank_statements.errors.bulk_ignore_reason_required"))
      expect(line.reload.status).to eq("unexpected")
    end

    it "lets a branch-scoped user ignore their branch's lines but not another branch's", :aggregate_failures do
      own   = line!(10)
      other = line!(20, statement: statement_for(other_branch))
      branch_user = user_with("view_deposit_verification", "verify_deposits", "manual_match_deposits", scope: "branch")
      branch.update!(branch_manager_id: branch_user.id) # Finance branch scope is management-based (BranchScope)
      sign_in branch_user

      post bulk_ignore_finance_deposit_verifications_path,
           params: { tab: "unexpected", transaction_ids: [ other.id ], reason: "x" }
      expect(flash[:alert]).to eq(I18n.t("finance.bank_statements.errors.bulk_ignore_unavailable"))
      expect(other.reload.status).to eq("unexpected")

      post bulk_ignore_finance_deposit_verifications_path,
           params: { tab: "unexpected", transaction_ids: [ own.id ], reason: "x" }
      expect(flash[:notice]).to eq(I18n.t("finance.deposit_verifications.bulk_ignore.done", count: 1))
      expect(own.reload.status).to eq("ignored")
    end

    it "refuses another business's lines and unknown ids, changing nothing", :aggregate_failures do
      own = line!(10)
      foreign_business = create(:business)
      foreign = BankStatementTransaction.create!(
        bank_statement: create(:bank_statement, :pending, business: foreign_business), business: foreign_business,
        amount: 10, transaction_date: day, raw_data: {}, status: "unexpected"
      )
      sign_in reviewer

      [ [ own.id, foreign.id ], [ 987_654_321 ], [ "abc" ] ].each do |ids|
        post bulk_ignore_finance_deposit_verifications_path,
             params: { tab: "unexpected", transaction_ids: ids, reason: "x" }
        expect(flash[:alert]).to be_present
      end
      expect([ own, foreign ].map { |t| t.reload.status }).to eq(%w[unexpected unexpected])
    end

    it "is refused without manual_match_deposits" do
      line = line!(10)
      sign_in user_with("view_deposit_verification")

      post bulk_ignore_finance_deposit_verifications_path,
           params: { tab: "unexpected", transaction_ids: [ line.id ], reason: "x" }

      expect(response).to redirect_to(root_path)
      expect(line.reload.status).to eq("unexpected")
    end
  end

  describe "returning a line to verification" do
    it "un-ignores from the transaction page with a reason, audited" do
      line = line!(10)
      Finance::BankStatements::Ignorer.call(line.id, actor: reviewer, reason: "fee")
      sign_in reviewer

      get finance_bank_statement_transaction_path(line)
      expect(response.body).to include(unignore_finance_bank_statement_transaction_path(line))

      patch unignore_finance_bank_statement_transaction_path(line), params: { unignore_reason: "Ignored by mistake" }

      expect(line.reload.status).to eq("unexpected")
      expect(AuditLog.where(auditable: line, action: "unignored").count).to eq(1)
    end
  end
end
