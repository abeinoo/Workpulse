module Payroll
  # Computes installment deductions for all active, auto-deductible obligations
  # belonging to a user that cover the given payroll period.
  #
  # Returns unsaved ObligationDeduction snapshots paired with their line-item
  # attribute hashes. Snapshots are saved by EntryCalculator inside the payroll
  # transaction — the before_create callback on ObligationDeduction decrements
  # the obligation's remaining_amount at that point.
  #
  # Idempotency: an existing snapshot for the same obligation+period is skipped,
  # so regenerating a draft period without first destroying old snapshots will not
  # create duplicate deductions.
  class ObligationDeductor
    DeductionItem   = Struct.new(:snapshot, :line_item_attrs, keyword_init: true)
    DeductionResult = Struct.new(:total_amount, :items, keyword_init: true)

    def self.call(user:, period:)
      new(user: user, period: period).call
    end

    def initialize(user:, period:)
      @user   = user
      @period = period
    end

    def call
      # Only the period's business: an obligation recorded under another
      # business is never deducted from this payroll (SEC-M2-4).
      obligations = EmployeeObligation
                      .active
                      .auto_deductible
                      .for_user(@user)
                      .where(business_id: @period.business_id)
                      .covering_period(@period)
                      .order(created_at: :asc)

      total = 0.0
      items = []

      obligations.each do |obligation|
        next if ObligationDeduction.exists?(
          employee_obligation: obligation,
          payroll_period:      @period
        )

        amount = obligation.installment_for_period(@period)
        next if amount <= 0

        remaining_before = obligation.remaining_amount.to_f

        snapshot = ObligationDeduction.new(
          employee_obligation: obligation,
          payroll_period:      @period,
          deducted_amount:     amount.round(2),
          remaining_before:    remaining_before.round(2),
          remaining_after:     (remaining_before - amount).clamp(0, Float::INFINITY).round(2)
        )

        total += amount
        items << DeductionItem.new(
          snapshot: snapshot,
          line_item_attrs: {
            item_type:    "obligation_deduction",
            description:  "#{obligation.title} — installment",
            amount:       -amount.round(2),
            source_type:  "ObligationDeduction",
            source_id:    nil,   # filled in after snapshot is saved
            review_status: "approved"
          }
        )
      end

      DeductionResult.new(total_amount: total.round(2), items: items)
    end
  end
end
