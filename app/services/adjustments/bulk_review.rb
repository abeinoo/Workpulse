module Adjustments
  # Approves or rejects many PayrollAdjustments in one request, processing each
  # record INDIVIDUALLY so per-row audit fields (approved_by/at, reviewed_by/at,
  # rejected_by/at) stay accurate — there is deliberately no bulk update_all and
  # no surrounding transaction, so one bad row never rolls back the others.
  #
  # The authorization rule is the same one used everywhere else: a reviewer needs
  # `approve_adjustments` AND must not be the creator (see Payroll::AdjustmentApproval).
  # Already-decided rows (anything not pending_review) are skipped, not failed.
  #
  # Outcome buckets:
  #   succeeded — transitioned to approved/rejected just now
  #   skipped   — already decided (approved/rejected) → nothing to do
  #   failed    — not permitted (e.g. reviewer is the creator), payroll period
  #               finalized/paid, or a save error
  class BulkReview
    Result = Struct.new(:action, :succeeded, :skipped, :failed, :failures, keyword_init: true) do
      def total          = succeeded + skipped + failed
      def any_succeeded? = succeeded.positive?
      def any_selected?  = total.positive?
    end

    def self.approve(adjustments:, reviewer:)
      new(adjustments: adjustments, reviewer: reviewer, action: :approve).call
    end

    def self.reject(adjustments:, reviewer:, notes: nil)
      new(adjustments: adjustments, reviewer: reviewer, action: :reject, notes: notes).call
    end

    def initialize(adjustments:, reviewer:, action:, notes: nil)
      @adjustments = Array(adjustments)
      @reviewer    = reviewer
      @action      = action.to_sym
      @notes       = notes
    end

    def call
      succeeded = skipped = failed = 0
      failures  = []

      @adjustments.each do |adjustment|
        # Only pending rows are actionable; anything already approved/rejected is
        # left untouched and reported as skipped (e.g. "Skipped: 2").
        unless adjustment.pending_review?
          skipped += 1
          next
        end

        unless permitted?(adjustment)
          failed += 1
          failures << failure(adjustment, :not_permitted)
          next
        end

        begin
          apply!(adjustment)
          succeeded += 1
        rescue StandardError => e
          failed += 1
          failures << failure(adjustment, e.message)
        end
      end

      Result.new(action: @action, succeeded: succeeded, skipped: skipped,
                 failed: failed, failures: failures)
    end

    private

    # Reuses THE single approval rule: holds approve_adjustments AND is not the creator.
    def permitted?(adjustment)
      Payroll::AdjustmentApproval.permitted?(reviewer: @reviewer, creator: adjustment.created_by_id)
    end

    def apply!(adjustment)
      if @action == :reject
        adjustment.reject_by!(@reviewer, notes: @notes)
      else
        # Per-row transaction (rows stay independent of each other): if
        # materialising fails, this row's approval is rolled back with it.
        ActiveRecord::Base.transaction do
          adjustment.approve_by!(@reviewer)
          # Materialise into an existing PayrollEntry so the entry stays in sync
          # without requiring a full period regeneration. No-ops when no entry exists.
          applied = Payroll::AdjustmentApplier.call(adjustment: adjustment)
          raise PayrollAdjustment::ReviewTransitionError, I18n.t("adjustments.errors.apply_failed") unless applied.success?
        end
      end
    end

    def failure(adjustment, reason)
      { id: adjustment.id, reason: reason }
    end
  end
end
