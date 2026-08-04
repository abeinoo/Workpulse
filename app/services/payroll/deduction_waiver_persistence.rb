module Payroll
  # The single mechanism for persisting a deduction waiver across a payroll
  # rebuild: capturing it before line items are destroyed, and reapplying it
  # after they are recreated. Applies identically to every waivable deduction
  # type — which types are waivable at all is a business-rule decision made in
  # PayrollLineItem::WAIVABLE_DEDUCTION_TYPES / #deduction_waivable?, not here.
  #
  # Used by both Payroll::Regenerator (whole period) and
  # Payroll::EntryRecalculator (single entry) so there is exactly one capture/
  # reapply implementation instead of one per deduction type.
  module DeductionWaiverPersistence
    module_function

    # Snapshot every currently-waived, waivable line item found in
    # `line_items_scope` (any AR relation/association of PayrollLineItem),
    # keyed by [user_id, waiver_identity] so a match survives the rebuild even
    # though every line item's own id is destroyed and recreated.
    def capture(line_items_scope)
      line_items_scope
        .where(deduction_waived: true)
        .includes(:payroll_entry)
        .each_with_object({}) do |li, memo|
          next unless li.deduction_waivable?

          memo[[ li.payroll_entry.user_id, li.waiver_identity ]] = {
            reason:       li.deduction_waiver_reason,
            waived_by_id: li.deduction_waived_by_id,
            waived_at:    li.deduction_waived_at
          }
        end
    end

    # Re-applies captured waivers to one rebuilt entry's line items. Returns
    # true when anything was touched, so the caller can recalculate the entry
    # exactly once rather than once per line item.
    def reapply_to_entry(entry, captured)
      return false if captured.blank?

      touched = false
      entry.payroll_line_items.each do |li|
        next unless li.deduction_waivable?

        prev = captured[[ entry.user_id, li.waiver_identity ]]
        next unless prev

        li.update!(
          deduction_waived:        true,
          deduction_waiver_reason: prev[:reason],
          deduction_waived_by_id:  prev[:waived_by_id],
          deduction_waived_at:     prev[:waived_at]
        )
        touched = true
      end
      touched
    end
  end
end
