module Payroll
  # Applies a payroll-level waiver to a single manual-deduction PayrollLineItem.
  #
  # The underlying PayrollAdjustment (the "manual deduction" source of truth) is
  # NEVER modified — the waiver lives only at the payroll layer, exactly like the
  # overtime override lives only on the entry. A waived deduction is excluded from
  # the entry's payable totals (net salary rises accordingly) but stays visible and
  # clearly marked. recalculate_totals! keeps net_salary in sync.
  #
  # action:
  #   "waive"   — excuse the deduction (requires a reason)
  #   "restore" — undo the waiver, the deduction applies again (no reason needed)
  #
  # Only manual deductions are waivable. Attendance penalties and other line items
  # are out of scope and rejected.
  class DeductionWaiver
    ACTIONS = %w[waive restore].freeze

    Result = Struct.new(:success, :line_item, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(line_item:, action:, actor:, reason: nil)
      new(line_item: line_item, action: action, actor: actor, reason: reason).call
    end

    def initialize(line_item:, action:, actor:, reason:)
      @line_item = line_item
      @action    = action.to_s
      @actor     = actor
      @reason    = reason.to_s.strip.presence
    end

    def call
      return err(I18n.t("payroll.deduction_waiver.errors.invalid_action")) unless ACTIONS.include?(@action)
      return err(I18n.t("payroll.deduction_waiver.errors.permission")) unless @actor.can?(:manage_payroll_deduction_waivers)

      period = @line_item.payroll_entry.payroll_period
      return err(I18n.t("payroll.deduction_waiver.errors.locked")) unless period&.reviewable?
      return err(I18n.t("payroll.deduction_waiver.errors.not_waivable")) unless @line_item.deduction_waivable?

      case @action
      when "waive"   then waive
      when "restore" then restore
      end
    rescue => e
      Rails.logger.error("[Payroll::DeductionWaiver] line_item=#{@line_item.id} failed: #{e.message}")
      err(e.message)
    end

    private

    def waive
      return err(I18n.t("payroll.deduction_waiver.errors.already_waived")) if @line_item.deduction_waived?
      return err(I18n.t("payroll.deduction_waiver.errors.reason_required")) if @reason.blank?

      apply!(
        deduction_waived:         true,
        deduction_waiver_reason:  @reason,
        deduction_waived_by:      @actor,
        deduction_waived_at:      Time.current
      )
      write_audit("deduction_waived", old_state: "active", new_state: "waived")
      Result.new(success: true, line_item: @line_item)
    end

    def restore
      return err(I18n.t("payroll.deduction_waiver.errors.not_waived")) unless @line_item.deduction_waived?

      apply!(
        deduction_waived:         false,
        deduction_waiver_reason:  nil,
        deduction_waived_by:      nil,
        deduction_waived_at:      nil
      )
      write_audit("deduction_restored", old_state: "waived", new_state: "active", reason: @reason)
      Result.new(success: true, line_item: @line_item)
    end

    def apply!(attrs)
      ActiveRecord::Base.transaction do
        @line_item.update!(attrs)
        @line_item.payroll_entry.recalculate_totals!
      end
    end

    def write_audit(action_type, old_state:, new_state:, reason: @reason)
      entry  = @line_item.payroll_entry
      PayrollAuditLog.create!(
        payroll_period: entry.payroll_period,
        actor:          @actor,
        action_type:    action_type,
        metadata:       {
          payroll_period_id: entry.payroll_period_id,
          payroll_entry_id:  entry.id,
          deduction_id:      @line_item.id,
          employee_id:       entry.user_id,
          amount:            @line_item.amount.abs.to_f,
          old_state:         old_state,
          new_state:         new_state,
          reason:            reason,
          actor_id:          @actor.id,
          timestamp:         Time.current.iso8601
        }.to_json
      )
    rescue => e
      Rails.logger.error("[PayrollAuditLog] #{action_type} write failed: #{e.message}")
    end

    def err(msg)
      Result.new(success: false, error: msg)
    end
  end
end
