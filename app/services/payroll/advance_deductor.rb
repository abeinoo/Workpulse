module Payroll
  # Computes advance deductions for a user at payroll generation time.
  # Advances are NOT repaid here — Advance#repay! is called only when the
  # payroll period is marked as paid, ensuring no money moves until final approval.
  #
  # An advance's remaining_amount only drops when its holding period is paid
  # (Approver#settle_advances!), so a second period generated for the same user
  # before that happens would otherwise see the same unpaid remaining_amount and
  # deduct it again. An advance already carrying an advance_deduction line item
  # on another not-yet-paid period is reserved there and skipped here — the
  # PayrollLineItem itself is the "which period owns this repayment" record,
  # not a stored flag on Advance.
  class AdvanceDeductor
    DeductionResult = Struct.new(:total_amount, :line_items, keyword_init: true)

    def self.call(user:, period:)
      new(user: user, period: period).call
    end

    def initialize(user:, period:)
      @user   = user
      @period = period
    end

    def call
      advances = Advance.active.for_user(@user).order(issued_at: :asc)
      total    = 0.0
      items    = []

      advances.each do |advance|
        amount = advance.remaining_amount.to_f
        next if amount <= 0
        next if reserved_in_another_period?(advance)

        total += amount
        items << {
          item_type:     "advance_deduction",
          description:   "Advance repayment (advance ##{advance.id})",
          amount:        -amount.round(2),
          source_type:   "Advance",
          source_id:     advance.id,
          review_status: "approved"
        }
      end

      DeductionResult.new(total_amount: total.round(2), line_items: items)
    end

    private

    def reserved_in_another_period?(advance)
      PayrollLineItem
        .advance_deduction
        .where(source_type: "Advance", source_id: advance.id)
        .joins(payroll_entry: :payroll_period)
        .where.not(payroll_periods: { id: @period.id })
        .where.not(payroll_periods: { status: "paid" })
        .exists?
    end
  end
end
