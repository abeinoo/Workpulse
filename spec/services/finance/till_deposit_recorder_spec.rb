require "rails_helper"

RSpec.describe Finance::TillDepositRecorder, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:cash_pm) do
    PaymentMethod.create!(
      business:        business,
      name:            "Cash",
      settlement_type: "cash",
      active:          true
    )
  end

  # DR in the state the recorder expects.
  let(:dr) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "closed",
      opened_at:     1.hour.ago,
      closed_at:     Time.current,
      business_date: Date.current
    )
  end

  # Both must exist before any service call fires.
  let!(:till_session)   { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(
      daily_reconciliation: dr,
      payment_method:       cash_pm,
      payment_method_name:  cash_pm.name,
      collected_amount:     500,
      refund_amount:        0
    )
  end

  let(:base_params) do
    {
      payment_method_id: cash_pm.id,
      amount:            "500.00",
      deposited_at:      Time.current.to_s
    }
  end

  def record(params: base_params, depositor: actor)
    described_class.new(dr.id, actor: depositor, params: params).call
  end

  describe "#call" do
    it "creates the deposit, advances DR to deposited, and returns ok" do
      result = record
      expect(result.ok?).to be true
      expect(result.deposit).to be_persisted
      expect(result.deposit.amount).to eq(500)
      expect(dr.reload.state).to eq("deposited")
    end

    it "does not advance state when DR is already deposited" do
      dr.update_columns(state: "deposited")
      result = record
      expect(result.ok?).to be true
      expect(dr.reload.state).to eq("deposited")
    end

    it "writes an audit log entry for the deposit" do
      record
      expect(AuditLog.where(auditable: TillDeposit.last, action: "create").count).to eq(1)
    end

    context "when the deposit covers the full expected amount" do
      it "does not create a RemainingDepositBalance" do
        result = record
        expect(result.remaining_amount).to be_nil
        expect(RemainingDepositBalance.count).to eq(0)
      end
    end

    context "when the deposit is short of the expected amount" do
      let(:short_params) { base_params.merge(amount: "300.00") }

      it "creates a RemainingDepositBalance for the shortfall" do
        result = record(params: short_params)
        expect(result.ok?).to be true
        expect(result.remaining_amount).to eq(200)
        balance = RemainingDepositBalance.last
        expect(balance.amount).to eq(200)
        expect(balance.remaining_amount).to eq(200)
        expect(balance.status).to eq("open")
        expect(balance.responsible_user).to eq(actor)
      end

      it "seeds a 'created' opening ledger entry for traceability" do
        record(params: short_params)
        entry = RemainingDepositBalance.last
                                       .balance_transactions
                                       .find_by(transaction_type: "created")
        expect(entry).to be_present
        expect(entry.amount).to eq(200)
        expect(entry.performed_by).to eq(actor)
      end
    end

    context "error cases" do
      it "rejects when the DR is not closed or deposited" do
        dr.update_columns(state: "open")
        result = record
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("till_deposits.errors.session_not_closed"))
      end

      it "rejects when the actor is not the designated depositor" do
        other = create(:user, business: business)
        result = record(depositor: other)
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("till_deposits.errors.not_depositor"))
      end

      it "rejects an unknown payment method" do
        result = record(params: base_params.merge(payment_method_id: 0))
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("till_deposits.errors.invalid_payment_method"))
      end
    end

    # ── Regression: inverse_of contamination from controller Pundit pattern ──────
    #
    # The controller does `TillDeposit.new(daily_reconciliation: dr)` to build a
    # record for Pundit authorization.  Rails' inverse_of pushes that blank unsaved
    # object into dr.till_deposits.target (even though the association is never
    # explicitly loaded).  With the old service interface — which accepted the same
    # AR object and called update!(state: "deposited") on it — Rails'
    # save_collection_association found the blank record via changed_for_autosave?
    # (true for any new_record?) and tried to validate it.  Validation failed with
    # "Payment method must exist / Amount can't be blank / …", and those errors
    # surfaced as the user-visible result, masking the actual deposit entirely.
    #
    # Fix: the service accepts a daily_reconciliation_id and loads its own fresh
    # DailyReconciliation instance, so controller-side in-memory contamination can
    # never reach the service's update! call.
    context "regression: controller-side inverse_of contamination" do
      it "succeeds even when a blank TillDeposit is attached to the DR in memory" do
        blank = TillDeposit.new(daily_reconciliation: dr)

        # Confirm the contamination actually occurred — the blank unsaved record
        # is in the association target, which is what triggered the original bug.
        expect(dr.till_deposits.target).to include(blank)

        result = record

        expect(result.ok?).to be true
        expect(result.error).to be_nil
        expect(dr.reload.state).to eq("deposited")

        # Exactly one deposit was persisted; the blank record was never saved.
        expect(TillDeposit.count).to eq(1)
        expect(TillDeposit.first.amount).to eq(500)
      end
    end
  end
end
