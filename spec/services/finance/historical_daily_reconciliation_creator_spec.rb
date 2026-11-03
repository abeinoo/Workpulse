require "rails_helper"

# A past-dated DR starts "open" like today's: its status comes from the
# explicit lifecycle (closed only by the Day Close handover), never from
# comparing business_date with the current business day.
RSpec.describe Finance::HistoricalDailyReconciliationCreator, type: :model do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:cash_pm)   { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:past_date) { BusinessDay.current(context: business) - 2.days }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:manager)  { user_with("view_daily_reconciliation", "create_till_session") }
  let(:cashier)  { user_with("close_till_session", "accept_till_handover", "create_till_deposit") }
  let(:cashier2) { user_with("close_till_session", "accept_till_handover", "create_till_deposit") }

  def create_past(date = past_date, on: branch)
    described_class.new(branch: on, business_date: date, actor: manager).call
  end

  describe "creation" do
    it "creates the past-dated DR as open, with an empty till session and no handovers" do
      result = create_past

      expect(result.ok?).to be true
      dr = result.reconciliation
      expect(dr.business_date).to eq(past_date)
      expect(dr.state).to eq("open")
      expect(dr.closed_at).to be_nil
      expect(dr.till_session).to be_present
      expect(dr.till_session.current_holder_id).to be_nil
      expect(dr.till_handovers).to be_empty
      expect(dr.day_close_handover).to be_nil
    end

    it "is open for an earlier date too, not only yesterday" do
      result = create_past(past_date - 30.days)

      expect(result.reconciliation.state).to eq("open")
    end

    it "writes exactly one create_historical audit entry, on the new DR, with branch and date" do
      dr = nil
      expect { dr = create_past.reconciliation }.to change(AuditLog, :count).by(1)

      log = AuditLog.last
      expect(log.action).to eq("create_historical")
      expect(log.actor).to eq(manager)
      expect(log.business_id).to eq(business.id)
      expect(log.auditable).to eq(dr)
      expect(log.metadata).to eq("branch_id" => branch.id, "business_date" => past_date.to_s)
    end

    it "writes no audit entry when refused" do
      DailyReconciliation.create_for!(branch: branch, business_date: BusinessDay.current(context: business))

      expect { create_past }.not_to change(AuditLog, :count)
    end

    it "maps a lost race on the one-open index to a failed Result instead of raising" do
      allow(DailyReconciliation).to receive(:create_for!)
        .and_raise(ActiveRecord::RecordNotUnique, 'duplicate key value violates unique constraint "idx_dr_one_open_per_branch"')

      result = create_past
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.another_day_open_or_waiting"))
    end
  end

  describe "one-open / one-waiting per branch" do
    it "is refused while the branch has another open DR, leaving it untouched" do
      other = DailyReconciliation.create_for!(branch: branch, business_date: BusinessDay.current(context: business))

      result = nil
      expect { result = create_past }.not_to change(DailyReconciliation, :count)

      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.another_day_open_or_waiting"))
      expect(other.reload.state).to eq("open")
    end

    it "is refused while the branch has a waiting_for_opening DR" do
      DailyReconciliation.create!(branch: branch, business: business, state: "waiting_for_opening",
                                  opened_at: Time.current, business_date: BusinessDay.current(context: business))

      expect(create_past.ok?).to be false
    end

    it "is allowed when the branch's other DRs are closed, and leaves them closed" do
      closed = DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                           opened_at: 1.day.ago, closed_at: 1.day.ago,
                                           business_date: BusinessDay.current(context: business))

      expect(create_past.reconciliation.state).to eq("open")
      expect(closed.reload.state).to eq("closed")
    end

    it "an open DR at another branch does not block this branch" do
      DailyReconciliation.create_for!(branch: create(:branch, business: business),
                                      business_date: BusinessDay.current(context: business))

      expect(create_past.ok?).to be true
    end

    it "rejects a duplicate (branch, business_date) even when the existing one is closed" do
      create_past
      DailyReconciliation.find_by(branch: branch, business_date: past_date).update!(state: "closed", closed_at: Time.current)

      result = nil
      expect { result = create_past }.not_to change(DailyReconciliation, :count)
      expect(result.ok?).to be false
    end
  end

  describe "the existing custody and closing workflow" do
    it "accepts a handover, establishes custody, and closes only through the explicit Day Close" do
      dr = create_past.reconciliation

      handover = Finance::TillHandoverCreator.new(
        actor: cashier, daily_reconciliation_id: dr.id,
        params: { to_user_id: cashier2.id,
                  amounts: { cash_pm.id.to_s => { collected_amount: "250", refund_amount: "0" } } }
      ).call
      expect(handover.ok?).to be true
      expect(handover.handover.fresha_date).to eq(past_date)

      expect(Finance::TillHandoverAcceptor.new(handover.handover.id, actor: cashier2).call.ok?).to be true
      expect(dr.till_session.reload.current_holder).to eq(cashier2)
      expect(dr.reload.state).to eq("open")

      close = Finance::TillHandoverCreator.new(
        actor: cashier2, daily_reconciliation_id: dr.id,
        params: { self_deposit: "1", depositor_type: "self",
                  amounts: { cash_pm.id.to_s => { collected_amount: "250", refund_amount: "0" } } }
      ).call
      expect(close.ok?).to be true

      dr.reload
      expect(dr.state).to eq("closed")
      expect(dr.closed_at).to be_present
      expect(dr.till_session.depositor).to eq(cashier2)
    end
  end
end
