module Payroll
  # "Approve all pending" for a payroll period — the single implementation behind
  # both PayrollPeriodsController#approve_all_pending (web) and
  # Api::V1::PayrollPeriodsController#approve_all_pending.
  #
  # All-or-nothing, in one transaction, lock order "period first" (as
  # Payroll::Approver): the period row is locked and re-read, so a finalization
  # cannot slip in between the editable check and the writes; then the pending
  # line items; then each source adjustment (PayrollAdjustment#approve_by!).
  #
  # Adjustment-sourced items obey the single approval rule
  # (Payroll::AdjustmentApproval — approve_adjustments AND not the creator) and are
  # SKIPPED, not approved, when it is not satisfied, so nobody self-approves via
  # "approve all". System-generated items (attendance penalties) have no creator
  # and are gated only by the caller's approve_all_pending? authorization. An
  # approved line item always carries its source adjustment to approved with it;
  # if that adjustment is no longer pending the whole run is refused
  # (PayrollAdjustment::ReviewTransitionError) rather than leaving them diverged.
  class PendingItemsApprover
    Result = Struct.new(:ok, :record, :error, :approved, :skipped, keyword_init: true) do
      def ok? = ok
    end

    def self.call(period_id:, reviewer:)
      new(period_id: period_id, reviewer: reviewer).call
    end

    def initialize(period_id:, reviewer:)
      @period_id = period_id
      @reviewer  = reviewer
    end

    def call
      approved = skipped = 0
      refusal  = nil
      period   = nil

      ActiveRecord::Base.transaction do
        period = PayrollPeriod.where(business_id: @reviewer.business_id).lock.find(@period_id)
        refusal = :not_reviewable unless period.editable?

        items = refusal ? [] : pending_items(period)
        refusal ||= :no_pending_items if items.empty?
        raise ActiveRecord::Rollback if refusal

        entry_ids = Set.new
        items.each do |item|
          if item.adjustment_sourced? &&
             !Payroll::AdjustmentApproval.permitted?(reviewer: @reviewer, creator: item.source_creator)
            skipped += 1
            next
          end

          item.update!(review_status: :approved, reviewed_by: @reviewer, reviewed_at: Time.current)
          item.source_adjustment&.approve_by!(@reviewer)
          entry_ids << item.payroll_entry_id
          approved += 1
        end

        # Recalculate each entry exactly once rather than once per item.
        PayrollEntry.where(id: entry_ids.to_a).includes(:payroll_line_items).each(&:recalculate_totals!)

        PayrollAuditLog.create!(
          payroll_period: period,
          actor:          @reviewer,
          action_type:    :adjustment_approved,
          metadata:       JSON.generate(bulk_approved: true, count: approved, skipped: skipped,
                                        approved_at: Time.current.iso8601)
        )
      end

      return Result.new(ok: false, record: period, error: refusal, approved: 0, skipped: 0) if refusal

      Result.new(ok: true, record: period, approved: approved, skipped: skipped)
    end

    private

    def pending_items(period)
      PayrollLineItem.joins(:payroll_entry)
                     .where(payroll_entries: { payroll_period_id: period.id })
                     .where(review_status: :pending_review)
                     .order(:id)
                     .lock
                     .to_a
    end
  end
end
