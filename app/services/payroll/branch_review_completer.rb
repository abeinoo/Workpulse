module Payroll
  # Branch manager marks their review as done for a period.
  # When all branch review slots are completed, the period auto-advances
  # to branch_review_completed.
  #
  # branch: nil completes the period's central review (its floating employees),
  # which only a business-level reviewer may do
  # (PayrollPeriodBranchReview.central_reviewer?). The completing user and time
  # are recorded on the slot (reviewer, completed_at), as for a branch slot.
  #
  # Every completion writes its own review_slot_completed audit event (actor,
  # slot, time; for the central slot also the fingerprint of the content
  # reviewed — Payroll::CentralReview), also while other slots stay open. The
  # central review is synced before the period may advance, so it never reaches
  # branch_review_completed with floating employees unreviewed.
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

      if @branch.nil? && !PayrollPeriodBranchReview.central_reviewer?(@reviewer)
        return err(I18n.t("payroll.errors.central_review_not_allowed"))
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
        log_slot_completed(review)

        clear_branch_needs_review
        Payroll::CentralReview.new(@period).sync!(actor: @reviewer)

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

    # Approving a branch's review is the natural "start clean" point for the
    # next edit cycle: any employee flagged Needs Review because of changes
    # made during this review cycle no longer needs a visual flag once the
    # branch manager has signed off. Scoped to employees actually assigned to
    # this branch during the period (not the whole period's entries) — for the
    # central review, the employees floating during the period.
    def clear_branch_needs_review
      assignments     = ShiftAssignment.active_during(@period.period_start, @period.period_end)
      branch_user_ids = (@branch ? assignments.where(branch_id: @branch.id) : assignments.floating).select(:user_id)

      entry_ids = @period.payroll_entries
                          .where(user_id: branch_user_ids, needs_review: true)
                          .pluck(:id)
      return if entry_ids.empty?

      Payroll::BulkEntryReviewClearer.call(period: @period, actor: @reviewer, entry_ids: entry_ids)
    end

    def log_slot_completed(review)
      metadata = { branch_id: review.branch_id, branch_name: @branch&.name, central: review.central?,
                   completed_at: review.completed_at.iso8601, notes: @notes.presence }
      metadata[:scope_digest] = Payroll::CentralReview.new(@period).scope_digest if review.central?

      PayrollAuditLog.create!(payroll_period: @period, actor: @reviewer, action_type: :review_slot_completed,
                              metadata: metadata.compact.to_json)
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
