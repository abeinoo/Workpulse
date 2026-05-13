module Payroll
  # Computes advance deductions for a user at payroll generation time.
  # Advances are NOT repaid here — Advance#repay! is called only when the
  # payroll period is marked as paid, ensuring no money moves until final approval.
  class AdvanceDeductor
    DeductionResult = Struct.new(:total_amount, :line_items, keyword_init: true)

    def self.call(user:)
      new(user: user).call
    end

    def initialize(user:)
      @user = user
    end

    def call
      advances = Advance.active.for_user(@user).order(issued_at: :asc)
      total    = 0.0
      items    = []

      advances.each do |advance|
        amount = advance.remaining_amount.to_f
        next if amount <= 0

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
  end
end
