module Finance
  module TillDeposits
    # Marks a TillDeposit as ignored — it will never appear on the bank
    # statement (e.g. reconciled outside the bank entirely) and should stop
    # being counted as "Missing from Bank" on the Deposit Verifications page.
    #
    # The deposit-side counterpart of Finance::BankStatements::Ignorer. Unlike
    # that one, this never touches any BankStatementTransaction — a deposit
    # with matched transactions already has a real bank-side counterpart and
    # must be unmatched first (via Finance::BankStatements::Unmatcher) before
    # it can be ignored.
    class Ignorer
      include AuditLoggable

      Result = Struct.new(:ok, :deposit, :error, keyword_init: true) { def ok? = ok }

      def self.call(till_deposit_id, actor:, reason: nil)
        new(till_deposit_id, actor: actor, reason: reason).call
      end

      def initialize(till_deposit_id, actor:, reason: nil)
        @till_deposit_id = till_deposit_id
        @actor           = actor
        @reason          = reason
      end

      def call
        deposit = TillDeposit
                    .joins(:daily_reconciliation)
                    .where(daily_reconciliations: { business_id: @actor.business_id })
                    .find(@till_deposit_id)

        return err("already_voided") if deposit.voided?
        return err("already_ignored") if deposit.ignored?
        return err("cannot_ignore_matched") if deposit.match_status != :unmatched

        previous_status = "missing"

        deposit.update!(ignored_at: Time.current, ignored_by: @actor, ignore_reason: @reason)

        log_audit(
          actor:     @actor,
          auditable: deposit,
          action:    :ignored,
          metadata:  {
            reason:           @reason,
            previous_status:  previous_status,
            new_status:       "ignored",
            amount:           deposit.amount.to_s,
            daily_reconciliation_id: deposit.daily_reconciliation_id
          }
        )

        Result.new(ok: true, deposit: deposit)
      rescue ActiveRecord::RecordNotFound
        Result.new(ok: false, deposit: nil, error: I18n.t("errors.messages.not_found"))
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, deposit: nil, error: e.record.errors.full_messages.to_sentence)
      end

      private

      def err(key)
        Result.new(ok: false, deposit: nil, error: I18n.t("till_deposits.errors.#{key}"))
      end
    end
  end
end
