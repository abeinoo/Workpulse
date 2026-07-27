module Finance
  module BankDisputes
    # Reverses whatever Finance::BankDisputes::RemainingBalanceReserver
    # claimed for this dispute, the moment it resolves (refunded, rejected,
    # or confirmed_successful) without yet becoming a real TillDeposit —
    # appends a dispute_released transaction restoring exactly the reserved
    # amount, per balance, and reopens any balance this dispute had fully
    # closed. Never mutates the earlier dispute_reserved transaction; this
    # is a new, separate ledger entry, per the append-only rule.
    #
    # Skips a balance that has since been settled or written off by a real,
    # independent action (a manager physically collected the shortfall, or
    # wrote it off) — that's a genuine terminal resolution the dispute
    # reversal must never undo.
    #
    # For confirmed_successful specifically, this reversal is deliberately
    # transient: Finance::BankDisputes::DepositConfirmer runs next (a
    # separate, deliberate accountant action) and creates the real
    # TillDeposit, whose existing Finance::TillDepositRecorder settlement
    # logic re-closes the reopened balance properly — via a genuine
    # "settlement" transaction, not this one.
    class RemainingBalanceReleaser
      include AuditLoggable

      def self.call(dispute, actor:)
        new(dispute, actor: actor).call
      end

      def initialize(dispute, actor:)
        @dispute = dispute
        @actor   = actor
      end

      def call
        reserved_txns = @dispute.remaining_deposit_balance_transactions
                                 .where(transaction_type: "dispute_reserved").to_a
        return if reserved_txns.empty?

        already_released = @dispute.remaining_deposit_balance_transactions
                                    .where(transaction_type: "dispute_released")
                                    .group(:remaining_deposit_balance_id).sum(:amount)

        reserved_txns.group_by(&:remaining_deposit_balance_id).each do |balance_id, txns|
          balance = RemainingDepositBalance.find(balance_id)
          next if balance.settled? || balance.written_off?

          reserved   = txns.sum(&:amount)
          released   = already_released[balance_id] || 0
          to_release = reserved - released
          next unless to_release.positive?

          release!(balance, to_release)
        end
      end

      private

      def release!(balance, amount)
        balance.balance_transactions.create!(
          transaction_type: "dispute_released",
          amount:           amount,
          performed_by:     @actor,
          bank_dispute:     @dispute,
          notes:            "Released — Bank Dispute ##{@dispute.id} resolved as #{@dispute.status}"
        )

        balance.update!(
          remaining_amount: balance.remaining_amount + amount,
          status:           "open",
          closed_at:        nil
        )

        log_audit(actor: @actor, auditable: balance, action: "dispute_released",
                  metadata: { amount: amount.to_s, bank_dispute_id: @dispute.id, dispute_status: @dispute.status })
      end
    end
  end
end
