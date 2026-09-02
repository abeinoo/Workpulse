require "rails_helper"

RSpec.describe "Mark deposit as ignored on the Deposit Verifications page", type: :request do
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

  def deposit(amount: 300)
    TillDeposit.create!(
      daily_reconciliation: daily_reconciliation, payment_method: payment_method,
      deposited_by: authorized_actor, amount: amount, deposited_at: business_date.to_time + 12.hours
    )
  end

  let(:authorized_actor) do
    user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit",
              "view_deposit_verification", "verify_deposits", "manual_match_deposits", "ignore_deposits")
  end

  describe "button visibility on the 'missing' tab" do
    it "shows 'تحديد كمتجاهل' to a user with ignore_deposits" do
      statement
      dep = deposit
      sign_in authorized_actor

      get finance_deposit_verifications_path(tab: "missing")

      expect(response.body).to include(I18n.t("till_deposits.show.ignore_button"))
      expect(response.body).to include(ignore_modal_till_deposit_path(dep))
    end

    it "hides the button from a user without ignore_deposits" do
      statement
      deposit
      viewer = user_with("view_deposit_verification", "verify_deposits", "manual_match_deposits")
      sign_in viewer

      get finance_deposit_verifications_path(tab: "missing")

      expect(response.body).not_to include(I18n.t("till_deposits.show.ignore_button"))
    end

    it "hides the ignore button once the deposit has a matched transaction" do
      statement
      dep = deposit(amount: 300)
      txn = BankStatementTransaction.create!(bank_statement: statement, business: business,
                                             transaction_date: business_date, amount: 300,
                                             raw_data: {}, status: "unexpected")
      Finance::BankStatements::ManualMatcher.call_many(
        till_deposit_id: dep.id, transaction_ids: [ txn.id ], actor: authorized_actor, notes: "confirmed"
      )
      sign_in authorized_actor

      get finance_deposit_verifications_path(tab: "all")

      expect(response.body).not_to include(ignore_modal_till_deposit_path(dep))
    end
  end

  describe "backend enforcement" do
    it "rejects GET ignore_modal from a user lacking ignore_deposits" do
      dep = deposit
      viewer = user_with("view_daily_reconciliation")
      sign_in viewer

      get ignore_modal_till_deposit_path(dep)

      expect(response).to redirect_to(root_path)
    end

    it "rejects PATCH ignore from a user lacking ignore_deposits" do
      dep = deposit
      viewer = user_with("view_daily_reconciliation")
      sign_in viewer

      patch ignore_till_deposit_path(dep), params: { ignore_reason: "test" }

      expect(response).to redirect_to(root_path)
      expect(dep.reload).not_to be_ignored
    end
  end

  describe "PATCH ignore" do
    it "marks the deposit ignored with the given optional reason" do
      statement
      dep = deposit
      sign_in authorized_actor

      patch ignore_till_deposit_path(dep), params: { ignore_reason: "Settled outside the bank" }

      expect(response).to redirect_to(finance_deposit_verifications_path(tab: "missing"))
      dep.reload
      expect(dep).to be_ignored
      expect(dep.ignore_reason).to eq("Settled outside the bank")
      expect(dep.ignored_by).to eq(authorized_actor)
    end

    it "removes the deposit from the 'missing' tab and updates counters" do
      statement
      dep = deposit
      sign_in authorized_actor

      patch ignore_till_deposit_path(dep), params: {}

      get finance_deposit_verifications_path(tab: "missing")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("a[href='#{till_deposit_path(dep)}']")).to be_nil
      expect(response.body).to include(I18n.t("finance.deposit_verifications.empty.missing"))
    end

    it "reflects the deposit under the 'ignored' tab and its counter, no longer counted as missing" do
      statement
      dep = deposit
      sign_in authorized_actor

      patch ignore_till_deposit_path(dep), params: { ignore_reason: "test" }

      get finance_deposit_verifications_path(tab: "ignored")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("a[href='#{till_deposit_path(dep)}']")).to be_present

      get finance_deposit_verifications_path(tab: "missing")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("a[href='#{till_deposit_path(dep)}']")).to be_nil
    end

    it "does not affect the missing/needs_review counters for other still-unresolved deposits" do
      statement
      dep_ignored  = deposit(amount: 300)
      dep_missing  = TillDeposit.create!(
        daily_reconciliation: daily_reconciliation, payment_method: payment_method,
        deposited_by: authorized_actor, amount: 400, deposited_at: business_date.to_time + 13.hours
      )
      sign_in authorized_actor

      patch ignore_till_deposit_path(dep_ignored), params: {}

      get finance_deposit_verifications_path(tab: "all")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("a[href='#{till_deposit_path(dep_missing)}']")).to be_present
    end

    it "rejects marking an already-ignored deposit again" do
      statement
      dep = deposit
      sign_in authorized_actor
      patch ignore_till_deposit_path(dep), params: {}

      patch ignore_till_deposit_path(dep), params: {}

      expect(response).to redirect_to(finance_deposit_verifications_path(tab: "missing"))
      follow_redirect!
      expect(response.body).to include(I18n.t("till_deposits.errors.already_ignored"))
    end

    it "rejects ignoring a deposit that is already matched" do
      statement
      dep = deposit(amount: 300)
      txn = BankStatementTransaction.create!(bank_statement: statement, business: business,
                                             transaction_date: business_date, amount: 300,
                                             raw_data: {}, status: "unexpected")
      Finance::BankStatements::ManualMatcher.call_many(
        till_deposit_id: dep.id, transaction_ids: [ txn.id ], actor: authorized_actor, notes: "confirmed"
      )
      sign_in authorized_actor

      patch ignore_till_deposit_path(dep), params: {}

      expect(dep.reload).not_to be_ignored
    end

    it "writes an audit log entry with actor, timestamp, deposit id, reason, and status transition" do
      statement
      dep = deposit
      sign_in authorized_actor

      patch ignore_till_deposit_path(dep), params: { ignore_reason: "Cash settled directly with owner" }

      log = AuditLog.for_auditable(dep).where(action: "ignored").last
      expect(log).to be_present
      expect(log.actor).to eq(authorized_actor)
      expect(log.created_at).to be_within(5.seconds).of(Time.current)
      expect(log.metadata["reason"]).to eq("Cash settled directly with owner")
      expect(log.metadata["previous_status"]).to eq("missing")
      expect(log.metadata["new_status"]).to eq("ignored")
    end
  end

  describe "PATCH unignore" do
    it "restores the deposit to the missing tab" do
      statement
      dep = deposit
      sign_in authorized_actor
      patch ignore_till_deposit_path(dep), params: {}

      patch unignore_till_deposit_path(dep)

      expect(dep.reload).not_to be_ignored

      get finance_deposit_verifications_path(tab: "missing")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("a[href='#{till_deposit_path(dep)}']")).to be_present
    end
  end

  describe "existing manual match flow stays unaffected" do
    it "still allows manually matching a non-ignored deposit" do
      statement
      dep = deposit(amount: 300)
      txn = BankStatementTransaction.create!(bank_statement: statement, business: business,
                                             transaction_date: business_date, amount: 300,
                                             raw_data: {}, status: "unexpected")
      sign_in authorized_actor

      patch manual_match_till_deposit_path(dep),
            params: { bank_statement_transaction_ids: [ txn.id ], match_notes: "confirmed" }

      expect(dep.reload.match_status).to eq(:fully_matched)
    end
  end
end
