module Payroll
  # Transitions a draft period to under_review and creates a
  # PayrollPeriodBranchReview slot for every branch that has employees
  # in this period (or just the period's specific branch if set), plus one
  # central slot (no branch, no reviewer yet) when the period has floating
  # employees — they belong to no branch, so no branch manager reviews them;
  # see PayrollPeriodBranchReview.central_reviewer?.
  #
  # Concurrency (R3.2 G4; attendance plan revision 19, OD-12, §19.14): the
  # decision is taken under the business's payroll-status lock (exclusive) and
  # the period's row lock, on the reloaded row — never on the object the caller
  # passed in. A backdated attendance-requirement change holds the same lock in
  # shared mode while it checks the period (Payroll::RequirementDateProtection),
  # so a period never becomes protected while such a change is in flight, and a
  # stale or duplicate submission is refused instead of being written twice.
  # Lock order: payroll-status lock → period row → review slots.
  class SubmitForReview
    REFUSAL = "Period must be draft (initial submission) or under_review with changes requested (resubmission)".freeze

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
      submitted = ActiveRecord::Base.transaction do
        Payroll::StatusLock.exclusive!(business_id: @period.business_id)
        @period.lock!
        if @period.draft?
          submit_initial!
        elsif @period.under_review? && @period.payroll_period_branch_reviews.changes_requested.any?
          resubmit!
        else
          next false
        end
        true
      end
      return err(REFUSAL) unless submitted

      Result.new(success: true, period: @period)
    rescue StandardError => e
      Result.new(success: false, error: e.message)
    end

    private

    def submit_initial!
      ActiveRecord::Base.transaction do
        create_branch_review_slots!
        create_central_review_slot!
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

    # The slots that requested changes go back to pending: their reviewer is
    # again the one the slot is assigned to — the branch manager for a branch
    # slot, nobody (any business-level reviewer) for the central one — never
    # the person who requested the changes (kept in the
    # branch_changes_requested audit event, with the comment). Then the central
    # review is synced: a floating employee who joined since, or a completed
    # central review whose content changed, is reviewed again
    # (Payroll::CentralReview).
    def resubmit!
      ActiveRecord::Base.transaction do
        @period.payroll_period_branch_reviews.changes_requested.includes(:branch).find_each do |review|
          review.update!(status: :pending, completed_at: nil, notes: nil,
                         reviewer_id: review.central? ? nil : (review.branch.branch_manager_id || review.reviewer_id))
        end
        Payroll::CentralReview.new(@period).sync!(actor: @by)
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

    def create_central_review_slot!
      return unless Payroll::CentralReview.new(@period).floating?

      PayrollPeriodBranchReview.find_or_create_by!(payroll_period: @period, branch: nil) do |r|
        r.status = :pending
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
