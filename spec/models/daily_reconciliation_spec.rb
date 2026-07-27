require "rails_helper"

RSpec.describe DailyReconciliation, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  describe "#reviewed?" do
    it "is false when reviewed_at is nil" do
      expect(dr.reviewed?).to be false
    end

    it "is true when reviewed_at is present" do
      dr.update_columns(reviewed_at: Time.current, reviewed_by_id: actor.id)
      expect(dr.reviewed?).to be true
    end
  end

  describe "#clear_review!" do
    it "clears reviewed_at/reviewed_by and logs an audit event when currently reviewed" do
      dr.update_columns(reviewed_at: 1.minute.ago, reviewed_by_id: actor.id)

      dr.clear_review!(actor: actor)

      expect(dr.reload.reviewed?).to be false
      expect(dr.reviewed_by_id).to be_nil
      log = AuditLog.where(auditable: dr, action: "review_auto_cancelled").sole
      expect(log.actor).to eq(actor)
      expect(log.metadata["reason"]).to eq("Financial data changed after review.")
    end

    it "is a no-op when not currently reviewed" do
      expect { dr.clear_review!(actor: actor) }.not_to change(AuditLog, :count)
    end
  end

  describe "open ATM Deposit Dispute reduces the remaining deposit amount" do
    let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
    let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
    let!(:session_amount) do
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 975, refund_amount: 0)
    end

    def atm_dispute(amount:, status: "new")
      BankDispute.create!(
        daily_reconciliation: dr, business: business, branch: branch, opened_by: actor,
        opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
        amount: amount, status: status, bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
      )
    end

    def missing_from_bank_dispute(amount:, status: "new")
      deposit = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                                    amount: amount, deposited_at: Time.current)
      BankDispute.create!(
        till_deposit: deposit, business: business, branch: branch, opened_by: actor,
        opened_at: Time.current, transaction_date: Date.current, kind: "missing_from_bank",
        amount: amount, status: status, bank_name: "NBE", terminal_id: "ATM-1"
      )
    end

    describe "#open_atm_dispute_amount" do
      it "sums open atm_deposit_failure disputes" do
        atm_dispute(amount: 200)
        expect(dr.open_atm_dispute_amount).to eq(200)
      end

      it "matches the business-rule example: expected 975, deposits 0, dispute 200 -> remaining 775" do
        atm_dispute(amount: 200)
        expect(dr.pending_deposit_amount).to eq(775)
      end

      %w[submitted_to_bank under_investigation].each do |status|
        it "still counts a dispute in the #{status} status as open" do
          atm_dispute(amount: 200, status: status)
          expect(dr.open_atm_dispute_amount).to eq(200)
        end
      end

      %w[refunded confirmed_successful rejected closed].each do |status|
        it "excludes a #{status} (resolved) dispute" do
          atm_dispute(amount: 200, status: status)
          expect(dr.open_atm_dispute_amount).to eq(0)
          expect(dr.pending_deposit_amount).to eq(975)
        end
      end

      it "does not double-count a missing_from_bank dispute (already inside total_deposited)" do
        missing_from_bank_dispute(amount: 300)
        expect(dr.open_atm_dispute_amount).to eq(0)
        expect(dr.pending_deposit_amount).to eq(975 - 300)
      end

      it "returns the amount to remaining once a dispute is refunded" do
        dispute = atm_dispute(amount: 200)
        expect(dr.pending_deposit_amount).to eq(775)

        dispute.update!(status: "rejected")
        expect(dr.pending_deposit_amount).to eq(975)
      end
    end

    describe "#remaining_by_payment_method" do
      it "subtracts the open dispute amount from the cash-like payment method" do
        atm_dispute(amount: 200)
        expect(dr.remaining_by_payment_method[cash_pm.id]).to eq(775)
      end

      it "never goes negative for a payment method even if disputes exceed its own total" do
        atm_dispute(amount: 2_000)
        expect(dr.remaining_by_payment_method[cash_pm.id]).to eq(0)
      end

      it "reflects an actual TillDeposit reducing the base before the dispute is applied" do
        TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                            amount: 100, deposited_at: Time.current)
        atm_dispute(amount: 200)
        expect(dr.remaining_by_payment_method[cash_pm.id]).to eq(975 - 100 - 200)
      end
    end

    describe "#remaining_by_payment_method with multiple cash-like payment methods" do
      # Regression for a real bug: the open dispute amount was previously
      # dumped entirely onto whichever payment method sorted first
      # (by position), so a small PM listed first could show a nonsensical
      # near-zero (or even wrong) figure while a much larger PM stayed fully
      # untouched. BankDispute has no payment_method_id, so the only
      # defensible split is proportional to each method's own remaining
      # base — verified here against the exact numbers from the report:
      # Expected 1,975 (325 + 1,650), Deposited 1,000 (all against the
      # larger method), open dispute 200 -> DR-wide remaining 775.
      let(:cash_pm_a) { PaymentMethod.create!(business: business, name: "Cash A", settlement_type: "cash", active: true, position: 1) }
      let(:cash_pm_b) { PaymentMethod.create!(business: business, name: "Cash B", settlement_type: "cash", active: true, position: 2) }

      before do
        # Neutralize the outer block's own cash_pm session amount (975) so
        # this DR's totals are driven solely by cash_pm_a/cash_pm_b below.
        session_amount.update!(collected_amount: 0)

        TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm_a, payment_method_name: "Cash A",
                                  collected_amount: 325, refund_amount: 0)
        TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm_b, payment_method_name: "Cash B",
                                  collected_amount: 1_650, refund_amount: 0)
        TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm_b, deposited_by: actor,
                            amount: 1_000, deposited_at: Time.current)
      end

      it "matches the DR-wide pending_deposit_amount exactly (975 base, 200 dispute -> 775)" do
        atm_dispute(amount: 200)

        expect(dr.pending_deposit_amount).to eq(775)
        expect(dr.remaining_by_payment_method.values.sum.round(2)).to eq(775.00)
      end

      it "never attributes the entire dispute to the smaller (first-positioned) payment method alone" do
        atm_dispute(amount: 200)

        remaining = dr.remaining_by_payment_method
        # Old buggy behavior gave Cash A exactly 125 (325 - 200) and left
        # Cash B untouched at 650 — neither should happen now.
        expect(remaining[cash_pm_a.id]).not_to eq(125)
        expect(remaining[cash_pm_b.id]).not_to eq(650)
      end

      it "distributes the dispute proportionally to each method's own remaining base" do
        atm_dispute(amount: 200)

        remaining = dr.remaining_by_payment_method
        # base_a=325, base_b=650, total_base=975, dispute=200
        # share_a = 200 * 325/975 = 66.67 -> 325 - 66.67 = 258.33
        # share_b = 200 * 650/975 = 133.33 -> 650 - 133.33 = 516.67
        expect(remaining[cash_pm_a.id].round(2)).to eq(258.33)
        expect(remaining[cash_pm_b.id].round(2)).to eq(516.67)
      end

      it "still allocates the full dispute to the sole cash method when only one exists (unchanged single-PM behavior)" do
        other_dr = DailyReconciliation.create!(
          branch: branch, business: business, state: "closed",
          opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current + 1.day
        )
        TillSession.create!(daily_reconciliation: other_dr, depositor_id: actor.id)
        TillSessionAmount.create!(daily_reconciliation: other_dr, payment_method: cash_pm, payment_method_name: "Cash",
                                  collected_amount: 1_975, refund_amount: 0)
        TillDeposit.create!(daily_reconciliation: other_dr, payment_method: cash_pm, deposited_by: actor,
                            amount: 1_000, deposited_at: Time.current)
        BankDispute.create!(
          daily_reconciliation: other_dr, business: business, branch: branch, opened_by: actor,
          opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
          amount: 200, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
        )

        expect(other_dr.pending_deposit_amount).to eq(775)
        expect(other_dr.remaining_by_payment_method[cash_pm.id]).to eq(775)
      end
    end
  end
end
