require "rails_helper"

RSpec.describe "Manual match action on the Daily Reconciliation bank deposits section", type: :request do
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

  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: depositor.id) }
  let(:depositor) { user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit") }

  let!(:dep) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: depositor,
                        amount: 5_000, deposited_at: Time.current)
  end

  describe "button visibility on the DR page" do
    it "is shown to a user with manual_match_deposits" do
      actor = user_with("view_daily_reconciliation", "view_deposit_verification", "verify_deposits",
                         "manual_match_deposits")
      sign_in actor

      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(I18n.t("finance.bank_statement_transactions.show.manual_match_button"))
      expect(response.body).to include(manual_match_modal_till_deposit_path(dep))
    end

    it "is hidden from a user without manual_match_deposits" do
      actor = user_with("view_daily_reconciliation", "view_deposit_verification")
      sign_in actor

      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include("مطابقة يدوية")
    end

    it "is hidden once the deposit is already fully matched" do
      statement = create(:bank_statement, business: business, branch: branch,
                         statement_from: 1.month.ago, statement_to: Date.current)
      txn = BankStatementTransaction.create!(bank_statement: statement, business: business,
                                             transaction_date: Date.current, amount: 5_000,
                                             raw_data: {}, status: "unexpected")
      matcher_actor = user_with("view_deposit_verification", "verify_deposits", "manual_match_deposits")
      Finance::BankStatements::ManualMatcher.call_many(
        till_deposit_id: dep.id, transaction_ids: [ txn.id ], actor: matcher_actor, notes: "confirmed"
      )

      actor = user_with("view_daily_reconciliation", "view_deposit_verification", "verify_deposits",
                         "manual_match_deposits")
      sign_in actor

      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(manual_match_modal_till_deposit_path(dep))
    end
  end

  describe "backend enforcement (direct request, no permission)" do
    it "rejects GET manual_match_modal from a user lacking manual_match_deposits" do
      actor = user_with("view_daily_reconciliation")
      sign_in actor

      get manual_match_modal_till_deposit_path(dep)

      expect(response).to redirect_to(root_path)
    end

    it "rejects PATCH manual_match from a user lacking manual_match_deposits" do
      statement = create(:bank_statement, business: business, branch: branch,
                         statement_from: 1.month.ago, statement_to: Date.current)
      txn = BankStatementTransaction.create!(bank_statement: statement, business: business,
                                             transaction_date: Date.current, amount: 5_000,
                                             raw_data: {}, status: "unexpected")
      actor = user_with("view_daily_reconciliation")
      sign_in actor

      patch manual_match_till_deposit_path(dep),
            params: { bank_statement_transaction_ids: [ txn.id ], match_notes: "confirmed" }

      expect(response).to redirect_to(root_path)
      expect(dep.reload.match_status).to eq(:unmatched)
      expect(txn.reload.matched?).to be false
    end
  end

  describe "audit trail" do
    it "records who performed the manual match and when" do
      statement = create(:bank_statement, business: business, branch: branch,
                         statement_from: 1.month.ago, statement_to: Date.current)
      txn = BankStatementTransaction.create!(bank_statement: statement, business: business,
                                             transaction_date: Date.current, amount: 5_000,
                                             raw_data: {}, status: "unexpected")
      actor = user_with("view_daily_reconciliation", "view_deposit_verification", "verify_deposits",
                         "manual_match_deposits")
      sign_in actor

      patch manual_match_till_deposit_path(dep),
            params: { bank_statement_transaction_ids: [ txn.id ], match_notes: "confirmed with branch" }

      log = AuditLog.for_auditable(txn).order(:created_at).last

      expect(log.action).to eq("manual_match")
      expect(log.actor).to eq(actor)
      expect(log.created_at).to be_within(5.seconds).of(Time.current)
      expect(log.metadata["till_deposit_id"]).to eq(dep.id)
      expect(log.metadata["notes"]).to eq("confirmed with branch")
    end
  end
end
