require "rails_helper"

# DR show page — the Void action label, and keeping bank transactions tied to
# a voided deposit visible for review (never hidden, never shown as verified).
RSpec.describe "Daily Reconciliation: voided deposits and bank review", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms, locale: "en")
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business, preferred_locale: locale)
      .tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "deposited",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let(:depositor) { user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit") }
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: depositor.id) }

  let(:reviewer_perms) do
    %w[view_daily_reconciliation view_deposit_verification verify_deposits manual_match_deposits void_till_deposit]
  end

  let(:statement) do
    create(:bank_statement, business: business, branch: branch,
           statement_from: Date.current - 2.days, statement_to: Date.current + 2.days)
  end

  def deposit(amount: 6_100)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: depositor,
                        amount: amount, deposited_at: Time.current)
  end

  def bank_txn(amount: 6_100, status: "unexpected")
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: amount,
                                     raw_data: {}, status: status, transaction_date: deposit_date)
  end

  def deposit_date = Time.current.to_date

  def manual_match!(txn, dep, actor)
    Finance::BankStatements::ManualMatcher.call(txn.id, till_deposit_id: dep.id, actor: actor, notes: "confirmed")
  end

  def matched_badge(count) = I18n.t("finance.daily_reconciliations.show.sections.bank.matched", count: count)

  describe "Void action label" do
    { "en" => "Void", "ar" => "إلغاء" }.each do |locale, label|
      it "renders the translated Void action on an active deposit (#{locale})" do
        deposit
        sign_in user_with(*reviewer_perms, locale: locale)

        get finance_daily_reconciliation_path(dr)

        html = Nokogiri::HTML(response.body)
        buttons = html.css("#bank-deposits form[action$='/void'] button").map { |b| b.text.strip }
        expect(buttons).to eq([ label ])
        expect(response.body).not_to include("translation_missing")
        expect(html.css("#bank-deposits .badge-danger").map(&:text).map(&:strip))
          .not_to include(I18n.t("finance.daily_reconciliations.show.sections.bank.voided_badge", locale: locale))
      end
    end

    it "shows a voided deposit with its Voided badge and no Void action" do
      d = deposit
      Finance::TillDepositVoider.new(d.id, actor: user_with(*reviewer_perms), void_reason: "wrong").call
      deposit(amount: 6_100) # replacement keeps the DR deposited
      sign_in user_with(*reviewer_perms)

      get finance_daily_reconciliation_path(dr)

      html = Nokogiri::HTML(response.body)
      expect(html.css("#bank-deposits .badge-danger").map { |b| b.text.strip }).to include("Voided")
      expect(html.css("#bank-deposits form[action='/till_deposits/#{d.id}/void']")).to be_empty
    end
  end

  describe "bank transactions tied to a voided deposit" do
    it "lists a transaction released by the void as an unmatched exception with Manual Match, not as matched" do
      reviewer = user_with(*reviewer_perms)
      original = deposit
      txn = bank_txn
      manual_match!(txn, original, reviewer)
      deposit # replacement, recorded first so the DR stays deposited
      Finance::TillDepositVoider.new(original.id, actor: reviewer, void_reason: "wrong slip").call
      sign_in reviewer

      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.sections.exceptions.bank_unexpected"))
      expect(response.body).to include(manual_match_modal_finance_bank_statement_transaction_path(txn))
      expect(response.body).to include(matched_badge(0))
    end

    it "keeps a legacy needs_reverification transaction still linked to a voided deposit visible" do
      reviewer = user_with(*reviewer_perms)
      original = deposit
      txn = bank_txn
      manual_match!(txn, original, reviewer)
      # State left behind by voids made before matches were released on void.
      original.update_columns(voided_at: Time.current, voided_by_id: reviewer.id, void_reason: "legacy")
      txn.update_columns(status: "needs_reverification")
      deposit # replacement
      sign_in reviewer

      get finance_daily_reconciliation_path(dr)

      expect(response.body)
        .to include(I18n.t("finance.daily_reconciliations.show.sections.exceptions.bank_needs_reverification"))
      expect(response.body).to include(finance_bank_statement_transaction_path(txn))
      expect(response.body).to include(matched_badge(0))
    end

    it "counts the replacement as matched once it is manually matched" do
      reviewer = user_with(*reviewer_perms)
      original = deposit
      txn = bank_txn
      manual_match!(txn, original, reviewer)
      replacement = deposit # recorded first so the DR stays deposited
      Finance::TillDepositVoider.new(original.id, actor: reviewer, void_reason: "wrong slip").call
      expect(manual_match!(txn, replacement, reviewer)).to be_ok
      sign_in reviewer

      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(matched_badge(1))
      expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.show.sections.exceptions.bank_unexpected"))
    end
  end
end
