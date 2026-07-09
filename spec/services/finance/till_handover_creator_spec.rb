require "rails_helper"

RSpec.describe Finance::TillHandoverCreator, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:sender)   { create(:user, :owner, business: business) }
  let(:receiver) { create(:user, business: business) }

  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "open",
      opened_at: 1.hour.ago, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, current_holder: sender) }

  def add_adjustment(handover:, actor:, after_data:)
    FinancialAdjustment.create!(
      adjustable: handover, business: business, actor: actor, reason_code: "wrong_amounts",
      notes: "Recount found a discrepancy at handover time",
      before_data: [ { payment_method_id: cash_pm.id, collected_amount: "370", refund_amount: "0" } ],
      after_data: after_data
    )
  end

  describe "#call minimum-amount validation" do
    it "uses the adjusted (effective) amount as the minimum, not the original" do
      received = TillHandover.create!(daily_reconciliation: dr, from_user: sender, to_user: receiver,
                                       self_deposit: false, accepted_at: 1.hour.ago, fresha_date: dr.business_date)
      TillHandoverAmount.create!(till_handover: received, payment_method: cash_pm, payment_method_name: "Cash",
                                  collected_amount: 370, refund_amount: 0, kind: "operational")
      add_adjustment(handover: received, actor: sender,
                     after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ])
      till_session.update!(current_holder: receiver)

      result = described_class.new(
        actor: receiver, daily_reconciliation_id: dr.id,
        params: { to_user_id: sender.id, amounts: { cash_pm.id.to_s => { collected_amount: "400", refund_amount: "0" } } }
      ).call

      expect(result.ok?).to be false
      expect(result.error).to include("470")
    end

    it "allows a hand-off that meets the adjusted minimum" do
      received = TillHandover.create!(daily_reconciliation: dr, from_user: sender, to_user: receiver,
                                       self_deposit: false, accepted_at: 1.hour.ago, fresha_date: dr.business_date)
      TillHandoverAmount.create!(till_handover: received, payment_method: cash_pm, payment_method_name: "Cash",
                                  collected_amount: 370, refund_amount: 0, kind: "operational")
      add_adjustment(handover: received, actor: sender,
                     after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ])
      till_session.update!(current_holder: receiver)

      result = described_class.new(
        actor: receiver, daily_reconciliation_id: dr.id,
        params: { to_user_id: sender.id, amounts: { cash_pm.id.to_s => { collected_amount: "470", refund_amount: "0" } } }
      ).call

      expect(result.ok?).to be true
    end
  end

  describe "#call amounts-present validation (hand-to-colleague)" do
    let(:bank_pm) { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true) }

    before do
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                                permissions: %w[view_daily_reconciliation accept_till_handover])
      receiver.update_column(:permission_role_id, role.id)
    end

    def hand_over(amounts)
      described_class.new(
        actor: sender, daily_reconciliation_id: dr.id,
        params: { to_user_id: receiver.id, amounts: amounts }
      ).call
    end

    it "rejects when all collected and refund amounts are zero" do
      result = hand_over(cash_pm.id.to_s => { collected_amount: "0", refund_amount: "0" })

      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.no_amounts_entered"))
      expect(TillHandover.count).to eq(0)
    end

    it "allows when one collected amount is greater than zero" do
      result = hand_over(cash_pm.id.to_s => { collected_amount: "50", refund_amount: "0" })

      expect(result.ok?).to be true
    end

    it "allows when one refund amount is greater than zero" do
      result = hand_over(cash_pm.id.to_s => { collected_amount: "0", refund_amount: "20" })

      expect(result.ok?).to be true
    end

    it "rejects when multiple payment methods are all zero" do
      result = hand_over(
        cash_pm.id.to_s => { collected_amount: "0", refund_amount: "0" },
        bank_pm.id.to_s => { collected_amount: "0", refund_amount: "0" }
      )

      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.no_amounts_entered"))
      expect(TillHandover.count).to eq(0)
    end

    it "cannot be bypassed by calling the service directly with blank amounts" do
      result = hand_over({})

      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_handovers.errors.no_amounts_entered"))
    end

    it "does not affect self-deposit (Day Close) — a zero-cash day is allowed to close" do
      result = described_class.new(
        actor: sender, daily_reconciliation_id: dr.id,
        params: { self_deposit: "1", depositor_type: "self",
                  amounts: { cash_pm.id.to_s => { collected_amount: "0", refund_amount: "0" } } }
      ).call

      expect(result.ok?).to be true
      expect(dr.reload.state).to eq("closed")
    end
  end

  describe "Branch Review invalidation" do
    before do
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                                permissions: %w[view_daily_reconciliation accept_till_handover])
      receiver.update_column(:permission_role_id, role.id)
    end

    it "clears an existing review when a new peer handover is created" do
      dr.update_columns(reviewed_at: 1.minute.ago, reviewed_by_id: sender.id)

      result = described_class.new(
        actor: sender, daily_reconciliation_id: dr.id,
        params: { to_user_id: receiver.id, amounts: { cash_pm.id.to_s => { collected_amount: "100", refund_amount: "0" } } }
      ).call

      expect(result.ok?).to be true
      expect(dr.reload.reviewed?).to be false
      expect(AuditLog.where(auditable: dr, action: "review_auto_cancelled")).to be_present
    end

    it "is a no-op when the DR was never reviewed" do
      result = described_class.new(
        actor: sender, daily_reconciliation_id: dr.id,
        params: { to_user_id: receiver.id, amounts: { cash_pm.id.to_s => { collected_amount: "100", refund_amount: "0" } } }
      ).call

      expect(result.ok?).to be true
      expect(AuditLog.where(auditable: dr, action: "review_auto_cancelled")).to be_empty
    end
  end

  describe ".sync_session_amounts!" do
    it "writes the effective (adjusted) amount into session_amounts, not the original" do
      handover = TillHandover.create!(daily_reconciliation: dr, from_user: sender, self_deposit: true,
                                       opening_float_declaration: false, accepted_at: 1.hour.ago,
                                       fresha_date: dr.business_date)
      TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm, payment_method_name: "Cash",
                                  collected_amount: 370, refund_amount: 0, kind: "operational")
      add_adjustment(handover: handover, actor: sender,
                     after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ])

      described_class.sync_session_amounts!(dr, handover)

      expect(dr.session_amounts.find_by(payment_method: cash_pm).collected_amount).to eq(470)
    end
  end
end
