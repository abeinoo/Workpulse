module Finance
  module TillDeposits
    # Reverses Ignorer — restores an ignored deposit back to "Missing from
    # Bank" (or wherever it now belongs, e.g. once a covering bank statement
    # has since been imported it may resurface as matched on the next import
    # run). Mirrors Finance::BankStatements::Unmatcher's simple clear-and-log
    # shape: no separate "un-ignore" state, just the ignore fields reset.
    class Unignorer
      include AuditLoggable

      Result = Struct.new(:ok, :deposit, :error, keyword_init: true) { def ok? = ok }

      def self.call(till_deposit_id, actor:)
        new(till_deposit_id, actor: actor).call
      end

      def initialize(till_deposit_id, actor:)
        @till_deposit_id = till_deposit_id
        @actor           = actor
      end

      def call
        deposit = TillDeposit
                    .joins(:daily_reconciliation)
                    .where(daily_reconciliations: { business_id: @actor.business_id })
                    .find(@till_deposit_id)

        return err("not_ignored") unless deposit.ignored?

        previous_reason = deposit.ignore_reason

        deposit.update!(ignored_at: nil, ignored_by: nil, ignore_reason: nil)

        log_audit(
          actor:     @actor,
          auditable: deposit,
          action:    :unignored,
          metadata:  { previous_reason: previous_reason, previous_status: "ignored", new_status: "missing" }
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
