module Payroll
  # Creates a PayrollLineItem from a PayrollAdjustment and updates the
  # employee's PayrollEntry totals. No-ops gracefully when no entry exists yet
  # (entry will be created with the adjustment included during generation).
  class AdjustmentApplier
    Result = Struct.new(:success, :line_item, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(adjustment:)
      new(adjustment: adjustment).call
    end

    def initialize(adjustment:)
      @adjustment = adjustment
    end

    def call
      entry = PayrollEntry.find_by(
        payroll_period: @adjustment.payroll_period,
        user:           @adjustment.user
      )
      return Result.new(success: true, line_item: nil) unless entry

      ActiveRecord::Base.transaction do
        li = entry.payroll_line_items.create!(
          item_type:     @adjustment.line_item_type,
          amount:        @adjustment.signed_amount,
          description:   @adjustment.reason,
          source_type:   "PayrollAdjustment",
          source_id:     @adjustment.id,
          # Mirror the adjustment's real status — NEVER hard-code "approved".
          # A pending adjustment yields a pending line item that does not count
          # toward net salary until a separate approver approves it.
          review_status: @adjustment.review_status,
          already_paid:  @adjustment.already_paid?
        )

        entry.recalculate_totals!

        Result.new(success: true, line_item: li)
      end
    rescue => e
      Result.new(success: false, error: e.message)
    end
  end
end
