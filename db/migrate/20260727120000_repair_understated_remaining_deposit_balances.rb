class RepairUnderstatedRemainingDepositBalances < ActiveRecord::Migration[8.0]
  # Data repair for a bug in Finance::TillDepositRecorder#reconcile_remaining_balance!
  # fixed alongside this migration: when an open RemainingDepositBalance existed for a
  # payment method (typically left orphaned after the deposit that created it was
  # voided/corrected) and a LATER deposit for that same payment method revealed a
  # LARGER true shortfall than the balance's stored remaining_amount, the old code
  # computed a negative "settlement_amount", silently did nothing, and left the
  # ledger permanently understating the true shortfall.
  #
  # This repairs every RemainingDepositBalance matching that exact, narrow pattern:
  #   - still open
  #   - its own till_deposit was voided
  #   - a LATER active till_deposit exists for the same (DR, payment method)
  #   - the balance has received no transaction since that later deposit was made
  #     (i.e. reconciliation never ran for it — the bug's signature)
  #
  # Deliberately NOT a blanket "make every RDB match the live formula" repair:
  # a RemainingDepositBalance can legitimately diverge from the live figure via a
  # manual settlement/write-off/adjustment recorded outside the ordinary deposit
  # flow (e.g. an employee reimburses cash directly, tracked by
  # Finance::RemainingDepositBalanceSettler with no new TillDeposit) — those are
  # correct as they stand and must never be touched by this repair.
  #
  # Appends an "adjustment" ledger transaction raising remaining_amount (and the
  # balance's own `amount`, so amount - remaining_amount / "settled since" keeps
  # meaning cumulative real settlements) up to the current live figure — never a
  # raw column UPDATE, so the repair produces the identical audit trail a live
  # Finance::TillDepositRecorder call would have, per this app's append-only
  # ledger rule.
  #
  # Safe to re-run: a balance already repaired has a transaction after its later
  # deposit's timestamp, so it no longer matches the candidate criteria.
  def up
    candidates = RemainingDepositBalance.open.includes(:till_deposit, :business, :branch)

    total = 0
    repaired = 0
    skipped = []

    candidates.find_each do |rdb|
      voided_deposit = rdb.till_deposit
      next unless voided_deposit&.voided_at

      dr = DailyReconciliation.find(rdb.daily_reconciliation_id)
      later_deposit = dr.till_deposits.active
                         .where(payment_method_id: voided_deposit.payment_method_id)
                         .where("created_at > ?", voided_deposit.voided_at)
                         .order(:created_at).first
      next unless later_deposit

      next if rdb.balance_transactions.where("created_at > ?", later_deposit.created_at).exists?

      total += 1
      live_remaining = dr.remaining_by_payment_method[voided_deposit.payment_method_id] || 0
      delta = live_remaining - rdb.remaining_amount

      unless delta.positive?
        skipped << [ rdb.id, "delta not positive (#{delta}) — not the understated-ledger bug shape, leaving untouched" ]
        next
      end

      actor = rdb.responsible_user || rdb.created_by
      unless actor
        skipped << [ rdb.id, "no responsible_user/created_by to attribute the correction to" ]
        next
      end

      ActiveRecord::Base.transaction do
        rdb.balance_transactions.create!(
          transaction_type: "adjustment",
          amount:           delta,
          performed_by:     actor,
          notes:            "Data repair: shortfall was understated after deposit ##{voided_deposit.id} was voided " \
                             "and deposit ##{later_deposit.id} was recorded without reconciling this balance " \
                             "(Finance::TillDepositRecorder bug, fixed #{Date.current.iso8601})."
        )

        rdb.update!(amount: rdb.amount + delta, remaining_amount: rdb.remaining_amount + delta)

        AuditLog.create!(
          actor:        actor,
          business:     actor.business,
          auditable:    rdb,
          action:       "adjustment",
          changes_json: {},
          metadata:     { amount: delta.to_s, reason: "data_repair_understated_shortfall", migration: self.class.name }
        )
      end

      repaired += 1
      say "  repaired RDB##{rdb.id} (dr=#{dr.id}): #{rdb.remaining_amount - delta} -> #{rdb.reload.remaining_amount}"
    end

    if total.zero?
      say "No RemainingDepositBalance matched the orphaned-and-understated pattern — nothing to repair."
    else
      say "Repaired #{repaired} of #{total} candidate balance(s)."
    end

    if skipped.any?
      say "Skipped #{skipped.size}:"
      skipped.each { |id, reason| say "  RDB##{id}: #{reason}" }
    end
  end

  def down
    say "Data repair migration — the original understated ledger values are not meaningfully recoverable and should not be restored."
  end
end
