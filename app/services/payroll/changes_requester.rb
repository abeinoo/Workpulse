module Payroll
  # A branch manager flags their review as needing changes, blocking the period
  # from advancing until accounting resubmits and the manager re-approves.
  # branch: nil does the same on the central review, for business-level
  # reviewers only (PayrollPeriodBranchReview.central_reviewer?).
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
      if @branch.nil? && !PayrollPeriodBranchReview.central_reviewer?(@reviewer)
        return err(I18n.t("payroll.errors.central_review_not_allowed"))
      end

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
          metadata:       audit_metadata.to_json
        )
      end

      Result.new(success: true, period: @period)
    rescue StandardError => e
      Result.new(success: false, error: e.message)
    end

    private

    def audit_metadata
      return { branch_id: @branch.id, branch_name: @branch.name, comment: @comment } if @branch

      { branch_id: nil, central: true, comment: @comment }
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
