module Finance
  module BankDisputes
    # The explicit accountant action once a bank has confirmed an ATM/POS
    # "failed deposit" dispute actually succeeded: creates the real
    # TillDeposit (deliberately not automatic — an intentional, reviewable
    # act, per this app's audit-first philosophy) and closes the dispute.
    #
    # Reuses Finance::TillDepositRecorder rather than a second deposit-
    # creation path, so RemainingDepositBalance reconciliation, idempotency,
    # and the review gate all apply exactly as they do for any other
    # deposit. The recorder's depositor-identity check runs against the
    # dispute's original reporter (dispute.opened_by), not the confirming
    # accountant — the deposit is attributed to whoever actually put the
    # cash in the ATM. If deposit responsibility has since moved to someone
    # else, the recorder's ordinary "not the depositor" error surfaces here;
    # the accountant resolves it the normal way (reassign the depositor, or
    # act as Super Admin) rather than this service silently overriding it.
    class DepositConfirmer
      include AuditLoggable

      Result = Struct.new(:ok, :dispute, :till_deposit, :error, keyword_init: true) { def ok? = ok }

      def initialize(bank_dispute_id, actor:, payment_method_id:, amount: nil)
        @bank_dispute_id    = bank_dispute_id
        @actor              = actor
        @payment_method_id  = payment_method_id
        @amount             = amount
      end

      def call
        dispute = BankDispute.where(business_id: @actor.business_id).find(@bank_dispute_id)

        return err(dispute, "not_confirmed_successful") unless dispute.status == "confirmed_successful"
        return err(dispute, "already_has_deposit") if dispute.till_deposit.present?

        dr = dispute.daily_reconciliation_for

        result = nil
        ActiveRecord::Base.transaction do
          recorder_result = Finance::TillDepositRecorder.new(
            dr.id,
            actor:  dispute.opened_by,
            params: {
              payment_method_id: @payment_method_id,
              amount:            @amount.presence || dispute.amount,
              deposited_at:      combined_transaction_time(dispute),
              reference:         dispute.reference_number,
              notes:             "Recorded from Bank Dispute ##{dispute.id} confirmation."
            }
          ).call

          unless recorder_result.ok?
            result = Result.new(ok: false, dispute: dispute, error: recorder_result.error)
            raise ActiveRecord::Rollback
          end

          dispute.update!(till_deposit: recorder_result.deposit)
          log_audit(actor: @actor, auditable: dispute, action: "deposit_recorded_from_dispute",
                    metadata: { till_deposit_id: recorder_result.deposit.id })

          transition_result = Finance::BankDisputes::StatusTransitioner.new(
            dispute.id, actor: @actor, target_status: "closed"
          ).call

          unless transition_result.ok?
            result = Result.new(ok: false, dispute: dispute, error: transition_result.error)
            raise ActiveRecord::Rollback
          end

          result = Result.new(ok: true, dispute: transition_result.dispute, till_deposit: recorder_result.deposit)
        end
        result
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, dispute: dispute, error: e.record.errors.full_messages.to_sentence)
      end

      private

      def combined_transaction_time(dispute)
        return dispute.transaction_date unless dispute.transaction_time

        Time.zone.local(dispute.transaction_date.year, dispute.transaction_date.month, dispute.transaction_date.day,
                        dispute.transaction_time.hour, dispute.transaction_time.min, dispute.transaction_time.sec)
      end

      def err(dispute, key)
        Result.new(ok: false, dispute: dispute, error: I18n.t("finance.bank_disputes.errors.#{key}"))
      end
    end
  end
end
