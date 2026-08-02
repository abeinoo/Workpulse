module Payroll
  # Advances a PayrollPeriod through its status machine.
  #
  # Normal path (auto-driven):
  #   draft → under_review            (via SubmitForReview)
  #   under_review → branch_review_completed  (via BranchReviewCompleter, once all branches done)
  #
  # Super admin path (this service):
  #   branch_review_completed → finalized   (normal final approval)
  #   under_review → finalized              (override: skip branch review)
  #   finalized → paid                      (settle advances)
  class Approver
    TRANSITIONS = {
      "branch_review_completed" => "finalized",
      "under_review"            => "finalized",  # super-admin override
      "finalized"               => "paid"
    }.freeze

    Result = Struct.new(:success, :period, :error, keyword_init: true) do
      def success? = success
    end

    def self.advance(period:, by:)
      new(period: period, by: by).advance
    end

    def initialize(period:, by:)
      @period = period
      @by     = by
    end

    def advance
      next_status = TRANSITIONS[@period.status]
      return err("No transition available from '#{@period.status}'") unless next_status

      ActiveRecord::Base.transaction do
        case next_status
        when "finalized"
          from = @period.status
          @period.update!(status: "finalized", finalized_by: @by, finalized_at: Time.current)
          PayrollAuditLog.create!(
            payroll_period: @period,
            actor:          @by,
            action_type:    :finalized,
            from_status:    from,
            to_status:      "finalized"
          )
          Payroll::InsuranceExpenseGenerator.call(period: @period, actor: @by)
        when "paid"
          settle_advances!
          @period.update!(status: "paid")
          PayrollAuditLog.create!(
            payroll_period: @period,
            actor:          @by,
            action_type:    :paid,
            from_status:    "finalized",
            to_status:      "paid"
          )
        end
      end

      Result.new(success: true, period: @period)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    rescue StandardError => e
      err(e.message)
    end

    private

    def settle_advances!
      @period.payroll_entries.includes(:payroll_line_items).each do |entry|
        entry.payroll_line_items.advance_deduction.each do |li|
          advance = Advance.find_by(id: li.source_id)
          advance&.repay!(li.amount.abs)
        end
      end
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
