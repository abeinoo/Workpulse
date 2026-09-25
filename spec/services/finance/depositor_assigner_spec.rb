require "rails_helper"

RSpec.describe Finance::DepositorAssigner, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms, **attrs)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business, **attrs).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def cashier(**attrs) = user_with("close_till_session", "create_till_deposit", **attrs)

  let(:manager) { user_with("view_daily_reconciliation", "verify_daily_reconciliation") }
  let(:ahmed)   { cashier(first_name: "Ahmed",   last_name: "Bahaa") }
  let(:mohamed) { cashier(first_name: "Mohamed", last_name: "Ahmed") }
  let(:mahmoud) { cashier(first_name: "Mahmoud", last_name: "Saeed") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 2.hours.ago, closed_at: 1.hour.ago, business_date: Date.current
    )
  end
  let!(:session) { TillSession.create!(daily_reconciliation: dr, depositor: ahmed, closed_by: ahmed) }
  let!(:amount)  do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 1_000, refund_amount: 50)
  end

  def transfer(to:, actor: manager, **opts)
    described_class.new(dr.id, actor: actor, depositor_id: to.id, **opts).call
  end

  def transfer_logs = AuditLog.where(auditable: dr, action: "assign_depositor").order(:created_at, :id)

  describe "successful transfer" do
    it "moves the depositor and records previous/new/actor/notes in the audit history" do
      result = transfer(to: mohamed, notes: "Ahmed left early", expected_depositor_id: ahmed.id)

      expect(result).to be_ok
      expect(result.depositor).to eq(mohamed)
      expect(result.previous_depositor).to eq(ahmed)
      expect(session.reload.depositor).to eq(mohamed)

      log = transfer_logs.sole
      expect(log.actor).to eq(manager)
      expect(log.metadata).to include(
        "previous_depositor_id" => ahmed.id, "previous_depositor_name" => "Ahmed Bahaa",
        "depositor_id" => mohamed.id, "depositor_name" => "Mohamed Ahmed",
        "notes" => "Ahmed left early"
      )
      expect(log.changes_json).to eq("depositor_id" => [ ahmed.id, mohamed.id ])
    end

    it "keeps every hop of repeated transfers in the history" do
      expect(transfer(to: mohamed)).to be_ok
      expect(transfer(to: mahmoud)).to be_ok
      expect(transfer(to: ahmed)).to be_ok

      hops = transfer_logs.map { |l| [ l.metadata["previous_depositor_name"], l.metadata["depositor_name"] ] }
      expect(hops).to eq([
        [ "Ahmed Bahaa", "Mohamed Ahmed" ],
        [ "Mohamed Ahmed", "Mahmoud Saeed" ],
        [ "Mahmoud Saeed", "Ahmed Bahaa" ]
      ])
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "is allowed while the day is deposited but cash is still owed" do
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, amount: 400,
                          deposited_by: ahmed, deposited_at: Time.current)
      dr.update!(state: "deposited")

      expect(transfer(to: mohamed)).to be_ok
      expect(session.reload.depositor).to eq(mohamed)
    end

    it "changes nothing but the depositor — amounts, deposits, handovers, POS data and DR fields are untouched" do
      deposit = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, amount: 300,
                                    deposited_by: ahmed, deposited_at: Time.current)
      dr.update!(state: "deposited")
      pos = create(:pos_transaction, business: business, branch: branch, amount: 250)

      snapshot = lambda do
        {
          dr:        dr.reload.attributes.slice("state", "business_date", "opened_at", "closed_at",
                                                "verified_at", "verified_by_id", "reviewed_at", "reviewed_by_id"),
          session:   session.reload.attributes.slice("closed_by_id", "current_holder_id"),
          amounts:   TillSessionAmount.where(daily_reconciliation: dr).pluck(:id, :collected_amount, :refund_amount, :updated_at),
          deposits:  TillDeposit.where(daily_reconciliation: dr).pluck(:id, :amount, :deposited_by_id, :voided_at, :updated_at),
          handovers: TillHandover.where(daily_reconciliation: dr).pluck(:id, :updated_at),
          balances:  RemainingDepositBalance.where(daily_reconciliation: dr).pluck(:id, :responsible_user_id, :updated_at),
          pos:       PosTransaction.where(business: business).pluck(:id, :amount, :status, :updated_at),
          expected:  [ dr.expected_cash_deposit, dr.total_deposited, dr.pending_deposit_amount ]
        }
      end

      before = snapshot.call
      expect(transfer(to: mohamed)).to be_ok
      expect(snapshot.call).to eq(before)
      expect(deposit.reload.deposited_by).to eq(ahmed)
      expect(pos.reload.amount).to eq(250)
    end
  end

  describe "guards" do
    it "rejects transferring to the current depositor" do
      result = transfer(to: ahmed)
      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.deposit_transfer_same_depositor", name: "Ahmed Bahaa"))
      expect(transfer_logs).to be_empty
    end

    it "rejects inactive employees" do
      mohamed.update!(active: false)
      result = transfer(to: mohamed)
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.deposit_transfer_ineligible", name: "Mohamed Ahmed"))
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "rejects employees who cannot record deposits" do
      viewer = user_with("view_daily_reconciliation")
      expect(transfer(to: viewer)).not_to be_ok
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "rejects users from another business" do
      outsider = create(:user)
      expect(transfer(to: outsider).error).to eq(I18n.t("finance.daily_reconciliations.errors.invalid_depositor"))
    end

    it "rejects a verified day — the completed deposit keeps its owner" do
      dr.update!(state: "verified", verified_at: Time.current, verified_by_id: manager.id)
      result = transfer(to: mohamed)
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.deposit_transfer_not_allowed"))
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "rejects a day whose cash is already fully deposited" do
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, amount: 950,
                          deposited_by: ahmed, deposited_at: Time.current)
      dr.update!(state: "deposited")
      expect(transfer(to: mohamed)).not_to be_ok
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "rejects a day that is still open" do
      dr.update!(state: "open", closed_at: nil)
      expect(transfer(to: mohamed)).not_to be_ok
    end

    it "rejects while an accept-flow transfer is pending (that flow is left intact)" do
      pending = DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: ahmed, to_user: mahmoud)
      result = transfer(to: mohamed)
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.pending_transfer_exists"))
      expect(pending.reload).to be_pending
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "rejects when the depositor the form was opened against is stale, naming who holds it now" do
      session.update!(depositor: mahmoud)
      result = transfer(to: mohamed, expected_depositor_id: ahmed.id)
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.deposit_transfer_stale", name: "Mahmoud Saeed"))
      expect(session.reload.depositor).to eq(mahmoud)
    end

    it "rejects notes over the length limit" do
      expect(transfer(to: mohamed, notes: "x" * 501)).not_to be_ok
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "rolls the reassignment back if its audit history cannot be written" do
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
      result = transfer(to: mohamed)
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.deposit_transfer_audit_failed"))
      expect(session.reload.depositor).to eq(ahmed)
    end
  end

  describe "concurrent transfers" do
    self.use_transactional_tests = false

    after do
      AuditLog.where(business: business).delete_all
      TillSessionAmount.where(daily_reconciliation: dr).delete_all
      TillSession.where(daily_reconciliation: dr).delete_all
      DailyReconciliation.where(id: dr.id).delete_all
      PaymentMethod.where(business: business).delete_all
      business.update_columns(owner_id: nil) if business.respond_to?(:owner_id)
      users = User.where(business: business)
      role_ids = users.pluck(:permission_role_id).compact
      users.delete_all
      PermissionRole.where(id: role_ids).delete_all
      Branch.where(business: business).delete_all
      Business.where(id: business.id).delete_all
    end

    it "lets exactly one of two simultaneous transfers from the same depositor win" do
      manager_b = user_with("view_daily_reconciliation", "verify_daily_reconciliation")
      targets   = [ mohamed, mahmoud ]
      [ manager, manager_b, dr, session, amount ].each(&:reload)

      results = []
      mutex   = Mutex.new
      threads = targets.zip([ manager, manager_b ]).map do |target, actor|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            r = described_class.new(dr.id, actor: actor, depositor_id: target.id,
                                    expected_depositor_id: ahmed.id).call
            mutex.synchronize { results << [ target, r ] }
          end
        end
      end
      threads.each(&:join)

      winners = results.select { |_, r| r.ok? }
      expect(winners.size).to eq(1)
      expect(session.reload.depositor).to eq(winners.first.first)
      loser = results.reject { |_, r| r.ok? }.sole.last
      expect(loser.error).to eq(I18n.t("finance.daily_reconciliations.errors.deposit_transfer_stale",
                                       name: winners.first.first.full_name))
      expect(transfer_logs.count).to eq(1)
    end
  end
end
