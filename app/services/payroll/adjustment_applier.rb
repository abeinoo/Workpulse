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
      # Standalone adjustments (created outside the payroll-review flow) have no
      # payroll_period_id. Fall back to looking up the period by business/month/year
      # so approval of a standalone adjustment can still materialise into an existing
      # PayrollEntry without requiring a full regeneration.
      period = @adjustment.payroll_period ||
               PayrollPeriod.find_by(
                 business:     @adjustment.business,
                 period_month: @adjustment.period_month,
                 period_year:  @adjustment.period_year
               )

      entry = period && PayrollEntry.find_by(payroll_period: period, user: @adjustment.user)
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
