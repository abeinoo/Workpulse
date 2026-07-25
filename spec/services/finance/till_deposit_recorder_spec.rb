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

  # DR in the state the recorder expects. Reviewed by default so existing
  # specs exercise the post-Branch-Review happy path; the review-guard
  # specs below explicitly unset this.
  let(:dr) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "closed",
      opened_at:     1.hour.ago,
      closed_at:     Time.current,
      business_date: Date.current,
      reviewed_by:   actor,
      reviewed_at:   1.minute.ago
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

      it "allows the business owner to record a deposit even when they are not the designated depositor" do
        owner = create(:user, business: business).tap { |u| business.update!(owner: u) }
        result = record(depositor: owner)
        expect(result.ok?).to be true
        expect(result.deposit.deposited_by).to eq(owner)
      end

      it "rejects an unknown payment method" do
        result = record(params: base_params.merge(payment_method_id: 0))
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("till_deposits.errors.invalid_payment_method"))
      end
    end

    context "Branch Review gate" do
      before { dr.update_columns(reviewed_at: nil, reviewed_by_id: nil) }

      it "rejects when unreviewed and the actor has no override permission" do
        result = record
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("till_deposits.errors.review_required"))
        expect(TillDeposit.count).to eq(0)
      end

      it "requires a reason when the actor holds override_review_requirement" do
        role = business.permission_roles.create!(name: "Super Admin #{SecureRandom.hex(3)}",
                                                   permissions: %w[view_daily_reconciliation override_review_requirement])
        actor.update_column(:permission_role_id, role.id)

        result = record
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("till_deposits.errors.override_reason_required"))
        expect(TillDeposit.count).to eq(0)
      end

      it "succeeds and logs the override when the actor has permission and a reason" do
        role = business.permission_roles.create!(name: "Super Admin #{SecureRandom.hex(3)}",
                                                   permissions: %w[view_daily_reconciliation override_review_requirement])
        actor.update_column(:permission_role_id, role.id)

        result = record(params: base_params.merge(override_review_reason: "Cashier leaving for the day, manager unreachable"))
        expect(result.ok?).to be true

        log = AuditLog.where(auditable: result.deposit, action: "deposit_review_overridden").sole
        expect(log.actor).to eq(actor)
        expect(log.metadata["reason"]).to eq("Cashier leaving for the day, manager unreachable")
      end

      it "does not require a reason once the DR is reviewed" do
        dr.update_columns(reviewed_at: Time.current, reviewed_by_id: actor.id)
        result = record
        expect(result.ok?).to be true
      end
    end

    context "multiple partial deposits against the same DR" do
      before { session_amount.update!(collected_amount: 5_000) }

      it "sums all deposits and recalculates the remaining amount after each one" do
        first = record(params: base_params.merge(amount: "4000.00"))
        expect(first.ok?).to be true
        expect(first.remaining_amount).to eq(1_000)
        expect(dr.reload.total_deposited).to eq(4_000)
        expect(dr.pending_deposit_amount).to eq(1_000)

        second = record(params: base_params.merge(amount: "700.00"))
        expect(second.ok?).to be true
        expect(second.remaining_amount).to eq(300)
        expect(dr.reload.total_deposited).to eq(4_700)
        expect(dr.pending_deposit_amount).to eq(300)

        expect(TillDeposit.count).to eq(2)
      end

      it "keeps each deposit as a separate, unmodified record" do
        first_result = record(params: base_params.merge(amount: "4000.00"))
        record(params: base_params.merge(amount: "700.00"))

        expect(first_result.deposit.reload.amount).to eq(4_000)
        expect(TillDeposit.order(:created_at).pluck(:amount)).to eq([ 4_000.to_d, 700.to_d ])
      end

      it "settles the open RemainingDepositBalance down as later deposits arrive, never fully covered until pending is 0" do
        record(params: base_params.merge(amount: "4000.00"))
        rdb = RemainingDepositBalance.sole
        expect(rdb.remaining_amount).to eq(1_000)
        expect(rdb.status).to eq("open")

        record(params: base_params.merge(amount: "700.00"))
        expect(rdb.reload.remaining_amount).to eq(300)
        expect(rdb.status).to eq("open")

        record(params: base_params.merge(amount: "300.00"))
        expect(rdb.reload.remaining_amount).to eq(0)
        expect(rdb.status).to eq("settled")
        expect(dr.reload.pending_deposit_amount).to eq(0)
      end

      it "is a no-op with zero deposits: total_deposited and pending_deposit_amount reflect the full expected amount" do
        expect(dr.total_deposited).to eq(0)
        expect(dr.pending_deposit_amount).to eq(5_000)
      end

      it "reaches fully-deposited only when cumulative deposits equal the expected amount, not before" do
        record(params: base_params.merge(amount: "4000.00"))
        expect(dr.reload.pending_deposit_amount).to be > 0

        record(params: base_params.merge(amount: "1000.00"))
        expect(dr.reload.pending_deposit_amount).to eq(0)
      end

      it "rejects a deposit that exceeds the currently remaining amount" do
        record(params: base_params.merge(amount: "4000.00"))

        result = record(params: base_params.merge(amount: "1500.00"))
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("till_deposits.errors.exceeds_remaining", remaining: "1000.0"))
        expect(TillDeposit.count).to eq(1)
      end

      it "rejects a single deposit larger than the full expected amount" do
        result = record(params: base_params.merge(amount: "6000.00"))
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("till_deposits.errors.exceeds_remaining", remaining: "5000.0"))
      end
    end

    context "idempotency" do
      before { session_amount.update!(collected_amount: 5_000) }

      it "does not create a duplicate deposit when the same idempotency_key is submitted twice" do
        key = SecureRandom.uuid
        first  = record(params: base_params.merge(amount: "4000.00", idempotency_key: key))
        second = record(params: base_params.merge(amount: "4000.00", idempotency_key: key))

        expect(first.ok?).to be true
        expect(second.ok?).to be true
        expect(second.deposit).to eq(first.deposit)
        expect(TillDeposit.count).to eq(1)
      end

      it "allows two distinct deposits with different idempotency keys" do
        record(params: base_params.merge(amount: "4000.00", idempotency_key: SecureRandom.uuid))
        record(params: base_params.merge(amount: "1000.00", idempotency_key: SecureRandom.uuid))

        expect(TillDeposit.count).to eq(2)
      end
    end

    context "race vs a second deposit" do
      before { session_amount.update!(collected_amount: 1_000) }

      # Sequential-call simulation: with_lock serializes the two calls on the
      # DR row lock, so by the time the second call runs it recomputes
      # already_deposited from the first call's committed total — proving a
      # concurrent over-deposit can never slip through, without needing real
      # threads (which would fight the spec's transactional wrapper).
      it "lets only the amount actually remaining succeed when two deposits race for the same balance" do
        first  = record(params: base_params.merge(amount: "700.00"))
        second = record(params: base_params.merge(amount: "700.00"))

        expect(first.ok?).to be true
        expect(second.ok?).to be false
        expect(second.error).to eq(I18n.t("till_deposits.errors.exceeds_remaining", remaining: "300.0"))
        expect(dr.reload.total_deposited).to eq(700)
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
