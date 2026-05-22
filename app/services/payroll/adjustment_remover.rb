module Payroll
  # Reverses a PayrollAdjustment's effect by destroying its line item and
  # restoring the entry totals. Safe to call even if no entry/line item exists.
  class AdjustmentRemover
    def self.call(adjustment:)
      new(adjustment: adjustment).call
    end

    def initialize(adjustment:)
      @adjustment = adjustment
    end

    def call
      li = PayrollLineItem.find_by(source_type: "PayrollAdjustment", source_id: @adjustment.id)
      return unless li

      entry = li.payroll_entry

      ActiveRecord::Base.transaction do
        li.destroy!
        entry.recalculate_totals!
      end
    end
  end
end
