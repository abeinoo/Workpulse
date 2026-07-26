class RepairOrphanedReviewedDailyReconciliations < ActiveRecord::Migration[8.0]
  # Data repair for the bug fixed alongside this migration: Finance::TillDepositVoider
  # used to revert a DailyReconciliation from "deposited" back to "closed" when its
  # last active deposit was voided, without clearing reviewed_at/reviewed_by_id.
  # That left the record in an impossible state — closed (no active deposit) yet
  # still "reviewed" — which the UI has no way to recover from: the Approval
  # section renders "Deposit Approved" forever, Record Deposit stays locked
  # (TillDepositPolicy#create? requires !reviewed?), and Cancel Review never
  # renders either (DailyReconciliationPolicy#cancel_review? requires deposited?,
  # which is false). See DR#46 in dev for a real example of this shape.
  #
  # This repairs every DR currently stuck in that exact shape by running them
  # through the same domain method the code fix now calls automatically:
  # DailyReconciliation#clear_review! — not a raw column UPDATE — so the repair
  # produces the identical review_auto_cancelled audit trail entry a live
  # TillDepositVoider call would have produced, preserving traceability.
  #
  # Audited as the DR's own reviewed_by (guaranteed present on every targeted
  # row, unlike business.owner which is optional) — there is no live actor for
  # a background data repair, so attributing it to the person whose now-invalid
  # approval is being cleared is the closest honest choice; the audit log
  # metadata + this migration's version number make it clear it was an
  # automated correction, not a manual re-cancellation by that person.
  #
  # Safe to re-run: DailyReconciliation#reviewed? gates every candidate, so a
  # record already repaired (reviewed_at nil) is simply skipped on a second run.
  def up
    candidates = DailyReconciliation
                   .closed
                   .where.not(reviewed_at: nil)
                   .where(<<~SQL.squish)
                     NOT EXISTS (
                       SELECT 1 FROM till_deposits td
                       WHERE td.daily_reconciliation_id = daily_reconciliations.id
                         AND td.voided_at IS NULL
                     )
                   SQL

    total = candidates.count
    if total.zero?
      say "No orphaned-reviewed DailyReconciliations found — nothing to repair."
      return
    end

    say "Found #{total} DailyReconciliation(s) stuck reviewed with zero active deposits — repairing..."

    repaired = 0
    skipped  = []

    candidates.find_each do |dr|
      # Re-check inside the loop: #closed / #reviewed_at / active deposits could
      # have changed between the COUNT above and this row's turn (unlikely in a
      # one-off maintenance run, but cheap to guard).
      unless dr.closed? && dr.reviewed? && dr.till_deposits.active.none?
        skipped << [ dr.id, "no longer matches the broken shape" ]
        next
      end

      actor = dr.reviewed_by
      unless actor
        skipped << [ dr.id, "reviewed_by_id is unexpectedly nil, cannot attribute the correction" ]
        next
      end

      dr.clear_review!(actor: actor)
      repaired += 1
      say "  repaired DR##{dr.id} (business_id=#{dr.business_id}, branch_id=#{dr.branch_id}, was reviewed_by=#{actor.id})"
    rescue => e
      skipped << [ dr.id, "#{e.class}: #{e.message}" ]
    end

    say "Repaired #{repaired} of #{total} DailyReconciliation(s)."
    if skipped.any?
      say "Skipped #{skipped.size}:"
      skipped.each { |id, reason| say "  DR##{id}: #{reason}" }
    end
  end

  def down
    say "Data repair migration — clearing reviewed_at is not reversible " \
        "(the original review timestamp/actor is not recoverable) and should not be undone."
  end
end
