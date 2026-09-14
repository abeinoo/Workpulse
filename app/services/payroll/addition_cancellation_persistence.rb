module Payroll
  # The single mechanism for persisting an addition/bonus cancellation across a
  # payroll rebuild: capturing it before line items are destroyed, and
  # reapplying it after they are recreated. Mirrors
  # Payroll::DeductionWaiverPersistence exactly, for the cancellation layer
  # instead of the waiver layer — see PayrollLineItem::CANCELLABLE_ADDITION_TYPES
  # / #addition_cancellable? for which types are eligible.
  #
  # Used by both Payroll::Regenerator (whole period) and
  # Payroll::EntryRecalculator (single entry) alongside DeductionWaiverPersistence.
  #
  # Applies to every cancellable addition, including system-generated overtime
  # line items — cancellability has no type allowlist (see
  # PayrollLineItem#addition_cancellable?), so neither does this module.
  module AdditionCancellationPersistence
    module_function

    # Snapshot every currently-cancelled, cancellable line item found in
    # `line_items_scope` (any AR relation/association of PayrollLineItem),
    # keyed by [user_id, waiver_identity] so a match survives the rebuild even
    # though every line item's own id is destroyed and recreated.
    def capture(line_items_scope)
      line_items_scope
        .where(addition_cancelled: true)
        .includes(:payroll_entry)
        .each_with_object({}) do |li, memo|
          next unless li.addition_cancellable?

          memo[[ li.payroll_entry.user_id, li.waiver_identity ]] = {
            reason:        li.addition_cancellation_reason,
            cancelled_by_id: li.addition_cancelled_by_id,
            cancelled_at:  li.addition_cancelled_at
          }
        end
    end

    # Re-applies captured cancellations to one rebuilt entry's line items.
    # Returns true when anything was touched, so the caller can recalculate
    # the entry exactly once rather than once per line item.
    def reapply_to_entry(entry, captured)
      return false if captured.blank?

      touched = false
      entry.payroll_line_items.each do |li|
        next unless li.addition_cancellable?

        prev = captured[[ entry.user_id, li.waiver_identity ]]
        next unless prev

        li.update!(
          addition_cancelled:           true,
          addition_cancellation_reason: prev[:reason],
          addition_cancelled_by_id:     prev[:cancelled_by_id],
          addition_cancelled_at:        prev[:cancelled_at]
        )
        touched = true
      end
      touched
    end
  end
end
