module Payroll
  # Approves or rejects a pending PayrollLineItem, then recalculates the parent
  # entry's stored totals from scratch so net_salary stays in sync.
  #
  # approve — confirms a pending_review item (manual deduction, penalty, bonus).
  #           Recalculates totals to include it.
  # reject  — removes a pending item from payroll. Since pending items are
  #           already excluded from stored totals, net_salary stays the same.
  #
  # Waiving an already-approved deduction is a separate concern — see
  # Payroll::DeductionWaiver — not handled here.
  class LineItemReviewer
    VALID_ACTIONS = %w[approve reject].freeze

    Result = Struct.new(:success, :line_item, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(line_item:, action:, reviewed_by:, notes: nil)
      new(line_item: line_item, action: action, reviewed_by: reviewed_by, notes: notes).call
    end

    def initialize(line_item:, action:, reviewed_by:, notes:)
      @line_item   = line_item
      @action      = action
      @reviewed_by = reviewed_by
      @notes       = notes
    end

    def call
      return err("Invalid action '#{@action}'") unless VALID_ACTIONS.include?(@action)

      # The single approval rule: reviewer needs approve_adjustments AND must not
      # be the creator of the underlying adjustment (creator != approver).
      unless Payroll::AdjustmentApproval.has_permission?(@reviewed_by)
        return err(I18n.t("adjustments.errors.review_permission"))
      end
      if Payroll::AdjustmentApproval.creator?(@reviewed_by, @line_item.source_creator)
        return err(I18n.t("adjustments.errors.review_own"))
      end

      refusal = nil

      ActiveRecord::Base.transaction do
        # Lock order "period first" (as Payroll::Approver): the period row, then
        # the line item; both re-read under the lock, so a finalization and this
        # review cannot both pass on stale state.
        period = PayrollPeriod.lock.find(@line_item.payroll_entry.payroll_period_id)
        @line_item.lock!
        refusal   = "Payroll period is already finalized" unless period.editable?
        refusal ||= "Only pending items can be approved or rejected" unless @line_item.pending_review?
        raise ActiveRecord::Rollback if refusal

        @line_item.update!(
          review_status: target_status,
          reviewed_by:   @reviewed_by,
          reviewed_at:   Time.current,
          review_notes:  @notes
        )
        sync_source_adjustment!
        @line_item.payroll_entry.recalculate_totals!
      end

      return err(refusal) if refusal

      Result.new(success: true, line_item: @line_item)
    rescue => e
      err(e.message)
    end

    private

    # Keeps the underlying PayrollAdjustment's review_status in lock-step with its
    # line item so that a later payroll regeneration (which only re-materialises
    # `approved` adjustments) reflects the decision, and so approved_by records the
    # real second-party approver. No-op for system-generated (attendance) items.
    def sync_source_adjustment!
      adjustment = @line_item.source_adjustment
      return unless adjustment

      case @action
      when "approve" then adjustment.approve_by!(@reviewed_by)
      when "reject"  then adjustment.reject_by!(@reviewed_by, notes: @notes)
      end
    end

    def target_status
      case @action
      when "approve" then "approved"
      when "reject"  then "rejected"
      end
    end

    def err(msg)
      Result.new(success: false, error: msg)
    end
  end
end
