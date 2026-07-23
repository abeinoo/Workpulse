require "rails_helper"

RSpec.describe "Deposit verification 'View' action is available for every status", type: :request do
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

  let(:viewer) { user_with("view_deposit_verification", "manual_match_deposits", "verify_deposits") }

  let(:payment_method) do
    PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
  end

  let(:business_date) { Date.new(2026, 7, 12) }

  let(:daily_reconciliation) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: business_date.to_time - 1.hour, business_date: business_date
    )
  end

  let(:statement) do
    create(:bank_statement, business: business, branch: branch,
           statement_from: business_date - 1.day, statement_to: business_date + 1.day)
  end

  def deposit(amount: 300, reference: nil, notes: nil)
    TillDeposit.create!(
      daily_reconciliation: daily_reconciliation, payment_method: payment_method,
      deposited_by: viewer, amount: amount, deposited_at: business_date.to_time + 12.hours,
      reference: reference, notes: notes
    )
  end

  def transaction(status:, amount: 300, matched_till_deposit_id: nil, match_method: nil, reference: nil)
    BankStatementTransaction.create!(
      bank_statement: statement, business: business, transaction_date: business_date,
      amount: amount, reference_number: reference, raw_data: {}, status: status,
      matched_till_deposit_id: matched_till_deposit_id, match_method: match_method,
      matched_at: (Time.current if matched_till_deposit_id)
    )
  end

  before { sign_in viewer }

  def view_links(body)
    Nokogiri::HTML(body).css("a, button").select { |el| el.text.strip == I18n.t("shared.view") }
  end

  describe "transactions table (unexpected / needs_review / mismatches tabs)" do
    it "renders View for a Missing from WorkPulse (unexpected) transaction" do
      transaction(status: "unexpected")
      get finance_deposit_verifications_path(tab: "unexpected")
      expect(view_links(response.body)).not_to be_empty
    end

    it "renders View for a Needs Manual Review transaction" do
      transaction(status: "needs_manual_review")
      get finance_deposit_verifications_path(tab: "needs_review")
      expect(view_links(response.body)).not_to be_empty
    end

    it "renders View for an amount_mismatch transaction" do
      d = deposit(amount: 250)
      transaction(status: "amount_mismatch", amount: 300, matched_till_deposit_id: d.id, match_method: "auto_amount_date")
      get finance_deposit_verifications_path(tab: "mismatches")
      expect(view_links(response.body)).not_to be_empty
    end

    it "renders View for a date_mismatch transaction" do
      d = deposit(amount: 300)
      transaction(status: "date_mismatch", amount: 300, matched_till_deposit_id: d.id, match_method: "auto_amount_near_date")
      get finance_deposit_verifications_path(tab: "mismatches")
      expect(view_links(response.body)).not_to be_empty
    end
  end

  describe "deposits table (all / missing tabs)" do
    it "renders View for a matched deposit" do
      d = deposit(amount: 300)
      transaction(status: "verified", amount: 300, matched_till_deposit_id: d.id, match_method: "auto_amount_date")

      get finance_deposit_verifications_path(tab: "all")
      expect(view_links(response.body)).not_to be_empty
    end

    it "renders View for a deposit missing from the bank statement (no bank_statement_transaction at all)" do
      statement # the "missing" tab only considers dates covered by an active, completed statement
      deposit(amount: 300)

      get finance_deposit_verifications_path(tab: "missing")
      expect(view_links(response.body)).not_to be_empty
    end

    it "renders both View and Manual Match for a missing deposit" do
      statement
      dep = deposit(amount: 300)

      get finance_deposit_verifications_path(tab: "missing")
      doc = Nokogiri::HTML(response.body)

      expect(doc.at_css("a[href='#{till_deposit_path(dep)}']")).to be_present
      expect(doc.at_css("a[href='#{manual_match_modal_till_deposit_path(dep)}']")).to be_present
    end
  end

  describe "bank statement's own transaction list (includes ignored rows)" do
    it "renders View for an ignored transaction" do
      transaction(status: "ignored")
      get finance_bank_statement_path(statement)
      expect(view_links(response.body)).not_to be_empty
    end

    it "renders View for every row regardless of status, on the same statement page" do
      transaction(status: "unexpected")
      transaction(status: "ignored")
      d = deposit(amount: 300)
      transaction(status: "verified", matched_till_deposit_id: d.id, match_method: "auto_amount_date")

      get finance_bank_statement_path(statement)
      expect(view_links(response.body).size).to eq(3)
    end
  end

  describe "clicking View always opens the same transaction/deposit details page" do
    it "the transaction View link points at the transaction show route" do
      txn = transaction(status: "unexpected")
      get finance_deposit_verifications_path(tab: "unexpected")

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("a[href='#{finance_bank_statement_transaction_path(txn)}']")).to be_present
    end

    it "the deposit View link points at the till_deposit show route" do
      statement
      dep = deposit(amount: 300)
      get finance_deposit_verifications_path(tab: "missing")

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("a[href='#{till_deposit_path(dep)}']")).to be_present
    end
  end
end
