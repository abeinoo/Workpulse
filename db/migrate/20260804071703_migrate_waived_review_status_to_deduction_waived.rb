class MigrateWaivedReviewStatusToDeductionWaived < ActiveRecord::Migration[8.1]
  # One-time data migration for the waiver-architecture unification: every
  # deduction type used to be waivable via review_status: "waived" (set by the
  # now-retired Payroll::LineItemReviewer#waive), with no capture/reapply
  # support for most types — waiving anything other than late/early-leave
  # penalty or manual_deduction silently lost its waived state on the next
  # payroll recalculation. Going forward, ALL waiving goes through the single
  # `deduction_waived` column (Payroll::DeductionWaiver /
  # Payroll::DeductionWaiverPersistence), gated by the explicit
  # PayrollLineItem::WAIVABLE_DEDUCTION_TYPES allowlist.
  #
  # For item types that ARE on the allowlist (late_penalty, early_leave_penalty,
  # manual_adjustment, manual_deduction, penalty): migrate the existing waiver
  # onto deduction_waived so it is preserved from now on instead of lost on the
  # next rebuild.
  #
  # For item types NOT on the allowlist (advance_deduction, obligation_deduction,
  # insurance_deduction): deliberately left untouched. Converting them would
  # silently decide "yes, these are waivable" in a data migration — a business
  # decision the team has explicitly deferred. review_status stays "waived"
  # (a legacy, no-longer-written value the review_status enum still tolerates),
  # so behavior for these specific rows is unchanged either way; flagged below
  # so it's visible rather than silent.
  def up
    migrated = execute(<<~SQL).cmd_tuples
      UPDATE payroll_line_items
      SET deduction_waived = true,
          deduction_waiver_reason = review_notes,
          deduction_waived_by_id = reviewed_by_id,
          deduction_waived_at = COALESCE(reviewed_at, updated_at),
          review_status = 'approved'
      WHERE review_status = 'waived'
        AND item_type IN (#{PayrollLineItem::WAIVABLE_DEDUCTION_TYPES.map { |t| connection.quote(t) }.join(', ')})
    SQL

    say "Migrated #{migrated} waivable-type line item(s) from review_status='waived' to deduction_waived=true."

    left_behind = execute(<<~SQL).to_a
      SELECT id, item_type FROM payroll_line_items
      WHERE review_status = 'waived'
        AND item_type NOT IN (#{PayrollLineItem::WAIVABLE_DEDUCTION_TYPES.map { |t| connection.quote(t) }.join(', ')})
    SQL

    if left_behind.any?
      say "#{left_behind.size} line item(s) left untouched (not on the waivable allowlist) — " \
          "still review_status='waived', unaffected by this migration:"
      left_behind.each { |row| say "  PayrollLineItem##{row['id']} (#{row['item_type']})" }
    end
  end

  def down
    say "Irreversible: rows converted by the 'up' direction can no longer be distinguished " \
        "from deductions waived directly via the new mechanism after this point."
  end
end
