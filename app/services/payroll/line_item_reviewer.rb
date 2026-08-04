module Payroll
  # Approves, rejects, or waives a PayrollLineItem, then recalculates the
  # parent entry's stored totals from scratch so net_salary stays in sync.
  #
  # approve — confirms a pending_review item (manual_deduction or bonus).
  #           Recalculates totals to include it.
  # reject  — removes a pending item from payroll. Since pending items are
  #           already excluded from stored totals, net_salary stays the same.
  # waive   — excuses an approved attendance or manual deduction. Requires a
  #           non-blank reason for audit purposes. Recalculates totals to
  #           exclude the waived amount.
  class LineItemReviewer
    VALID_ACTIONS = %w[approve reject waive].freeze

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
      return err("A reason is required to waive a deduction") if waive? && @notes.blank?

      # The single approval rule: reviewer needs approve_adjustments AND must not
      # be the creator of the underlying adjustment (creator != approver).
      unless Payroll::AdjustmentApproval.has_permission?(@reviewed_by)
        return err(I18n.t("adjustments.errors.review_permission"))
      end
      if Payroll::AdjustmentApproval.creator?(@reviewed_by, @line_item.source_creator)
        return err(I18n.t("adjustments.errors.review_own"))
      end

      period = @line_item.payroll_entry.payroll_period
      return err("Payroll period is already finalized") unless period.editable?

      case @action
      when "approve", "reject"
        return err("Only pending items can be approved or rejected") unless @line_item.pending_review?
      when "waive"
        return err("Only active deductions can be waived") unless waiveable?
      end

      ActiveRecord::Base.transaction do
        @line_item.update!(
          review_status: target_status,
          reviewed_by:   @reviewed_by,
          reviewed_at:   Time.current,
          review_notes:  @notes
        )
        sync_source_adjustment!
        @line_item.payroll_entry.recalculate_totals!
      end

      write_waive_audit if waive?

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

    def waive?
      @action == "waive"
    end

    # Attendance deductions start as approved; manual deductions start as pending.
    # Both can be waived as long as they haven't already been reversed.
    def waiveable?
      @line_item.deduction? && (@line_item.pending_review? || @line_item.approved?)
    end

    def target_status
      case @action
      when "approve" then "approved"
      when "reject"  then "rejected"
      when "waive"   then "waived"
      end
    end

    def write_waive_audit
      entry  = @line_item.payroll_entry
      period = entry.payroll_period
      PayrollAuditLog.create!(
        payroll_period: period,
        actor:          @reviewed_by,
        action_type:    "line_item_waived",
        metadata:       {
          line_item_id:     @line_item.id,
          item_type:        @line_item.item_type,
          employee_id:      entry.user_id,
          payroll_entry_id: entry.id,
          previous_amount:  @line_item.amount.to_f,
          new_amount:       0.0,
          reason:           @notes
        }.to_json
      )
    rescue => e
      Rails.logger.error("[PayrollAuditLog] line_item_waived write failed: #{e.message}")
    end

    def err(msg)
      Result.new(success: false, error: msg)
    end
  end
end
