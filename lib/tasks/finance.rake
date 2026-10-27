namespace :finance do
  desc <<~DESC
    Backfill: repair DailyReconciliations affected by the pre-fix Session/Branch
    Totals correction flow.

    Before the fix, Finance::SessionAmountsEditor wrote corrected amounts
    directly onto TillSessionAmount (session_amounts) without touching the
    day-close handover's TillHandoverAmount rows. Because the live Cashier/
    Guard Custody Summary and POS per-cashier breakdown (both driven by
    Finance::EmployeeReconciliationSummarizer, which reads the handover graph)
    never saw those corrections, they kept showing the pre-correction amount,
    and the persisted employee_reconciliation_summaries snapshot went stale too.

    This task finds every DR with at least one "edit_session_totals" audit log
    (i.e. went through the old flow), and where the day-close handover's
    operational amounts still diverge from session_amounts, pushes
    session_amounts (the corrected value) back onto the handover, then
    re-derives session_amounts and the persisted employee summary from it —
    the same write-through path Finance::SessionAmountsEditor now uses. Records
    already in sync (no divergence found) are left untouched.

    Idempotent — safe to re-run; a second run finds no divergence and updates
    nothing.

    Edge case: if a DR's Session Totals correction was followed by a later Day
    Close Amounts edit, the old Finance::DayCloseEditor's sync_session_amounts!
    call would already have silently overwritten session_amounts back to the
    (then-stale) handover value before this fix existed — the original
    correction is unrecoverable from current data. This task cannot safely
    reconstruct it, so those DRs are listed separately under "MANUAL REVIEW
    NEEDED" at the end of the run instead of being folded into the normal
    skip/update counts. Inspect their edit_session_totals audit log's
    changes_json by hand.

    Options (all via ENV):
      DRY_RUN=1        Report what would change without writing anything.
      BUSINESS_ID=42   Restrict to one business.
      ACTOR_ID=7       Audit-log actor for the correction. Defaults to each
                        affected DR's business owner.

    Usage:
      bin/rails finance:backfill_session_amounts_corrections DRY_RUN=1
      bin/rails finance:backfill_session_amounts_corrections
      bin/rails finance:backfill_session_amounts_corrections BUSINESS_ID=42
  DESC
  task backfill_session_amounts_corrections: :environment do
    dry_run     = ENV["DRY_RUN"].present?
    business_id = ENV["BUSINESS_ID"].presence
    actor_id    = ENV["ACTOR_ID"].presence
    override_actor = actor_id ? User.find(actor_id) : nil

    audit_scope = AuditLog.where(auditable_type: "DailyReconciliation", action: "edit_session_totals")
    dr_scope    = DailyReconciliation.where(id: audit_scope.select(:auditable_id))
    dr_scope    = dr_scope.where(business_id: business_id) if business_id

    dr_ids = dr_scope.distinct.pluck(:id)

    puts "[#{dry_run ? "DRY RUN" : "APPLY"}] #{dr_ids.size} Daily Reconciliation(s) have a Session/Branch Totals correction in their audit history."

    updated             = 0
    in_sync             = 0
    no_handover         = 0
    failed              = 0
    needs_manual_review = []

    dr_ids.each do |dr_id|
      dr = DailyReconciliation.find(dr_id)
      handover = dr.day_close_handover

      unless handover
        no_handover += 1
        puts "  DR ##{dr.id}: SKIPPED — no day-close handover found"
        next
      end

      earliest_session_edit_at = audit_scope.where(auditable_id: dr.id).minimum(:created_at)
      if earliest_session_edit_at &&
         AuditLog.where(auditable: handover, action: "edit_day_close_amounts")
                 .where("created_at > ?", earliest_session_edit_at)
                 .exists?
        needs_manual_review << dr.id
        puts "  DR ##{dr.id}: FLAGGED — a Day Close Amounts edit happened after a Session Totals correction; original correction may be unrecoverable"
      end

      diffs = {}
      dr.session_amounts.includes(:payment_method).each do |sa|
        ha = handover.amounts.operational.find_by(payment_method_id: sa.payment_method_id)
        next unless ha
        next if ha.collected_amount == sa.collected_amount && ha.refund_amount == sa.refund_amount

        diffs[sa.payment_method_name] = {
          collected: [ ha.collected_amount.to_s, sa.collected_amount.to_s ],
          refund:    [ ha.refund_amount.to_s,    sa.refund_amount.to_s ]
        }
      end

      if diffs.empty?
        in_sync += 1
        puts "  DR ##{dr.id}: SKIPPED — handover already matches session_amounts, no drift found"
        next
      end

      updated += 1
      puts "  DR ##{dr.id}: #{dry_run ? "WOULD UPDATE" : "UPDATED"} — #{diffs.keys.join(", ")}"

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          dr.session_amounts.includes(:payment_method).each do |sa|
            ha = handover.amounts.operational.find_by(payment_method_id: sa.payment_method_id)
            next unless ha
            next if ha.collected_amount == sa.collected_amount && ha.refund_amount == sa.refund_amount

            ha.update!(collected_amount: sa.collected_amount, refund_amount: sa.refund_amount)
          end

          Finance::TillHandoverCreator.sync_session_amounts!(dr, handover)
          Finance::EmployeeReconciliationSummarizer.new(dr).persist!

          actor = override_actor || dr.business.owner || User.where(business_id: dr.business_id).order(:id).first
          if actor
            AuditLog.create!(
              actor:        actor,
              business:     dr.business,
              auditable:    dr,
              action:       "backfill_session_amounts_correction",
              changes_json: diffs,
              metadata:     { note: "Resynced day-close handover from session_amounts after the SessionAmountsEditor write-through fix",
                              triggered_by: "rake finance:backfill_session_amounts_corrections" }
            )
          else
            Rails.logger.warn("[finance:backfill_session_amounts_corrections] DR ##{dr.id}: no actor found for audit log")
          end
        end
      rescue => e
        # One bad record must not abort the whole backfill — the transaction above
        # already rolled back any partial writes for this DR, so it's untouched and
        # will be retried (or investigated) on the next run.
        updated -= 1
        failed  += 1
        Rails.logger.error("[finance:backfill_session_amounts_corrections] DR ##{dr.id} failed: #{e.class}: #{e.message}")
        puts "  DR ##{dr.id}: FAILED — #{e.class}: #{e.message}"
      end
    end

    puts "---"
    puts "#{dry_run ? "Would update" : "Updated"}: #{updated}"
    puts "Skipped (already in sync): #{in_sync}"
    puts "Skipped (no day-close handover): #{no_handover}" if no_handover > 0
    puts "Failed: #{failed}" if failed > 0
    puts "Total examined: #{dr_ids.size}"
    puts "Run with DRY_RUN=1 to preview without applying changes." unless dry_run
    puts "#{failed} record(s) failed and were left untouched — safe to re-run once investigated (see log)." if failed > 0

    if needs_manual_review.any?
      puts "---"
      puts "MANUAL REVIEW NEEDED (#{needs_manual_review.size}): Session Totals correction followed by a later Day Close Amounts edit."
      puts "The Day Close edit's sync_session_amounts! call would have overwritten session_amounts back to the (then-stale)"
      puts "handover value, silently reverting the original Session Totals correction before this fix existed. This backfill"
      puts "cannot safely reconstruct the intended value — inspect each DR's edit_session_totals audit log changes_json by hand:"
      needs_manual_review.each { |id| puts "  DR ##{id}" }
    end
  end
end

namespace :finance do
  desc <<~DESC
    Stale bank matches: deposit matches left on transactions of DELETED bank
    statements (deleted before statement deletion released its matches). Such a
    match keeps its deposit "matched" to bank evidence no one can see, so no
    later statement can match that deposit.

    DRY RUN BY DEFAULT — lists every stale match of the business with a safety
    verdict and writes nothing. Releasing requires BOTH an explicit list of
    MATCH_IDS and EXECUTE=1; there is no "release all" mode. Each release goes
    through Finance::BankStatements::Unmatcher (audit action
    released_by_statement_deletion with repair: true) in its own transaction,
    re-checking safety under row locks; unsafe or ambiguous records are skipped.
    It never matches anything — run Rematch on the affected statement
    afterwards, from the UI, as a separate decision.

    Options (all via ENV):
      BUSINESS_ID=2      Required.
      MATCH_IDS=652,653  Matches to release (from the dry-run list).
      ACTOR_ID=12        Required with EXECUTE=1 — the audited user (same business).
      EXECUTE=1          Actually release. Without it, MATCH_IDS are only previewed.

    Usage:
      bin/rails finance:stale_bank_matches BUSINESS_ID=2
      bin/rails finance:stale_bank_matches BUSINESS_ID=2 MATCH_IDS=652
      bin/rails finance:stale_bank_matches BUSINESS_ID=2 MATCH_IDS=652 ACTOR_ID=12 EXECUTE=1
  DESC
  task stale_bank_matches: :environment do
    business  = Business.find(ENV.fetch("BUSINESS_ID"))
    match_ids = ENV["MATCH_IDS"].to_s.split(",").map(&:strip).reject(&:empty?)
    execute   = ENV["EXECUTE"] == "1"
    actor     = ENV["ACTOR_ID"].presence && User.find_by!(id: ENV["ACTOR_ID"], business_id: business.id)
    repair    = Finance::BankStatements::StaleMatchRepair.new(business: business, actor: actor)

    if match_ids.empty?
      abort "EXECUTE=1 needs MATCH_IDS — nothing is released without naming it." if execute

      items = repair.report
      puts "[DRY RUN] #{items.size} stale match(es) on deleted statements for business ##{business.id}:"
      items.each do |i|
        puts "  match##{i.match_id} txn##{i.transaction_id} stmt##{i.statement_id} deposit##{i.deposit_id} " \
             "DR##{i.daily_reconciliation_id} amount=#{i.amount.to_s('F')} txn_status=#{i.transaction_status} " \
             "=> #{i.verdict}#{" (#{i.reason})" if i.reason}"
      end
      puts "Nothing was changed."
      next
    end

    abort "EXECUTE=1 needs ACTOR_ID (a user of this business) for the audit trail." if execute && actor.nil?

    outcomes = repair.repair!(match_ids: match_ids, execute: execute)
    puts "[#{execute ? 'EXECUTE' : 'DRY RUN'}] business ##{business.id}:"
    outcomes.each { |o| puts "  match##{o.match_id} => #{o.result}#{" (#{o.reason})" if o.reason}" }
    tally = outcomes.group_by(&:result).transform_values(&:size)
    puts "Summary: #{tally}"
    puts "Nothing was changed." unless execute
  end
end
