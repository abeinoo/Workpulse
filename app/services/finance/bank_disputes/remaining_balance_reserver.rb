module Finance
  module BankDisputes
    # Reserves cash out of the open RemainingDepositBalance ledger the moment
    # an ATM Deposit Dispute (kind: atm_deposit_failure) is opened — the
    # employee has already declared what happened to this money, so it must
    # stop looking like an unexplained shortfall while the dispute is
    # investigated. Appends a dispute_reserved transaction per affected
    # balance; never mutates a past transaction, per this app's append-only
    # ledger rule.
    #
    # BankDispute carries no payment_method_id, so when more than one open
    # RemainingDepositBalance exists on the DR, the dispute amount is split
    # proportionally to each balance's own remaining_amount — the same
    # fairness rule DailyReconciliation#remaining_by_payment_method already
    # uses for the live (unposted) figure, so the ledger and the live
    # calculation always agree on how the same ambiguity is resolved.
    #
    # A balance whose remaining_amount is driven to exactly zero by this
    # reservation moves to status "disputed" (never "settled" — no cash
    # actually arrived) so it correctly drops out of every "still open,
    # still needs attention" scope (dashboard counts, bulk settle) without
    # pretending to be paid. RemainingBalanceReleaser reopens it if the
    # dispute later resolves without becoming a real deposit.
    #
    # No-op when there is no open balance at all — the ordinary case, since
    # most ATM disputes are reported before any deposit (let alone a
    # shortfall) exists yet.
    class RemainingBalanceReserver
      include AuditLoggable

      def self.call(dispute, actor:)
        new(dispute, actor: actor).call
      end

      def initialize(dispute, actor:)
        @dispute = dispute
        @actor   = actor
      end

      def call
        return unless @dispute.atm_deposit_failure?

        open_balances = @dispute.daily_reconciliation_for
                                 .remaining_deposit_balances.open.order(:id).to_a
        return if open_balances.empty?

        total_open = open_balances.sum(&:remaining_amount)
        return unless total_open.positive?

        pool = [ @dispute.amount, total_open ].min

        open_balances.each do |balance|
          share = (pool * balance.remaining_amount / total_open).round(2)
          next unless share.positive?

          reserve!(balance, share)
        end
      end

      private

      def reserve!(balance, amount)
        new_remaining  = balance.remaining_amount - amount
        fully_reserved = new_remaining.zero?

        balance.balance_transactions.create!(
          transaction_type: "dispute_reserved",
          amount:           amount,
          performed_by:     @actor,
          bank_dispute:     @dispute,
          notes:            "Reserved by open Bank Dispute ##{@dispute.id}"
        )

        balance.update!(
          remaining_amount: new_remaining,
          status:           fully_reserved ? "disputed" : "open",
          closed_at:        fully_reserved ? Time.current : nil
        )

        log_audit(actor: @actor, auditable: balance, action: "dispute_reserved",
                  metadata: { amount: amount.to_s, bank_dispute_id: @dispute.id })
      end
    end
  end
end
