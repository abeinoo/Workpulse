module Payroll
  # Transitions a draft period to under_review and creates a
  # PayrollPeriodBranchReview slot for every branch that has employees
  # in this period (or just the period's specific branch if set).
  class SubmitForReview
    Result = Struct.new(:success, :period, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(period:, by:)
      new(period: period, by: by).call
    end

    def initialize(period:, by:)
      @period = period
      @by     = by
    end

    def call
      if @period.draft?
        submit_initial!
      elsif @period.under_review? && @period.payroll_period_branch_reviews.changes_requested.any?
        resubmit!
      else
        return err("Period must be draft (initial submission) or under_review with changes requested (resubmission)")
      end

      Result.new(success: true, period: @period)
    rescue StandardError => e
      Result.new(success: false, error: e.message)
    end

    private

    def submit_initial!
      ActiveRecord::Base.transaction do
        create_branch_review_slots!
        @period.update!(status: :under_review)
        PayrollAuditLog.create!(
          payroll_period: @period,
          actor:          @by,
          action_type:    :submitted_for_review,
          from_status:    "draft",
          to_status:      "under_review"
        )
      end
    end

    def resubmit!
      ActiveRecord::Base.transaction do
        @period.payroll_period_branch_reviews.changes_requested.update_all(
          status:       "pending",
          completed_at: nil,
          notes:        nil
        )
        PayrollAuditLog.create!(
          payroll_period: @period,
          actor:          @by,
          action_type:    :resubmitted_for_review
        )
      end
    end

    def create_branch_review_slots!
      branches_needing_review.each do |branch|
        PayrollPeriodBranchReview.find_or_create_by!(
          payroll_period: @period,
          branch:         branch
        ) do |r|
          r.reviewer = branch.branch_manager
          r.status   = :pending
        end
      end
    end

    # All branches that have at least one employee in this period and have a manager assigned.
    def branches_needing_review
      user_ids   = @period.payroll_entries.pluck(:user_id)
      branch_ids = ShiftAssignment.branch_ids_for_users(
        user_ids, from: @period.period_start, to: @period.period_end
      )
      Branch.where(id: branch_ids).where.not(branch_manager_id: nil)
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
