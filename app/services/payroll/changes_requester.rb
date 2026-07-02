module Payroll
  # A branch manager flags their review as needing changes, blocking the period
  # from advancing until accounting resubmits and the manager re-approves.
  class ChangesRequester
    Result = Struct.new(:success, :period, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(period:, branch:, reviewer:, comment:)
      new(period: period, branch: branch, reviewer: reviewer, comment: comment).call
    end

    def initialize(period:, branch:, reviewer:, comment:)
      @period   = period
      @branch   = branch
      @reviewer = reviewer
      @comment  = comment
    end

    def call
      return err("Period must be under_review to request changes") unless @period.under_review?
      return err("A comment is required when requesting changes") if @comment.blank?

      review = PayrollPeriodBranchReview.find_by(payroll_period: @period, branch: @branch)
      return err("No review slot found for this branch on this period") unless review
      return err("This branch has already approved the review") if review.completed?

      ActiveRecord::Base.transaction do
        review.update!(
          status:       :changes_requested,
          completed_at: Time.current,
          reviewer:     @reviewer,
          notes:        @comment
        )

        PayrollAuditLog.create!(
          payroll_period: @period,
          actor:          @reviewer,
          action_type:    :branch_changes_requested,
          metadata:       { branch_id: @branch.id, branch_name: @branch.name, comment: @comment }.to_json
        )
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
