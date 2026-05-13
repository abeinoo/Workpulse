module Payroll
  # Branch manager marks their review as done for a period.
  # When all branch review slots are completed, the period auto-advances
  # to branch_review_completed.
  class BranchReviewCompleter
    Result = Struct.new(:success, :period, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(period:, branch:, reviewer:, notes: nil)
      new(period: period, branch: branch, reviewer: reviewer, notes: notes).call
    end

    def initialize(period:, branch:, reviewer:, notes: nil)
      @period   = period
      @branch   = branch
      @reviewer = reviewer
      @notes    = notes
    end

    def call
      unless @period.under_review?
        return err("Period must be under_review before a branch review can be completed")
      end

      review = PayrollPeriodBranchReview.find_by(payroll_period: @period, branch: @branch)
      return err("No review slot found for this branch on this period") unless review
      return err("This branch review is already completed") if review.completed?

      ActiveRecord::Base.transaction do
        review.update!(
          status:       :completed,
          completed_at: Time.current,
          reviewer:     @reviewer,
          notes:        @notes
        )

        if @period.reload.all_branches_reviewed?
          @period.update!(status: :branch_review_completed)
          PayrollAuditLog.create!(
            payroll_period: @period,
            actor:          @reviewer,
            action_type:    :branch_review_completed,
            from_status:    "under_review",
            to_status:      "branch_review_completed"
          )
        end
      end

      Result.new(success: true, period: @period)
    rescue StandardError => e
      Result.new(success: false, error: e.message)
    end

    private

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
