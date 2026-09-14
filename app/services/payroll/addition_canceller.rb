module Payroll
  # Applies a payroll-level cancellation to a single addition/bonus
  # PayrollLineItem — any line item shown in the "الإضافات والمكافآت" section
  # (see PayrollLineItem#addition_cancellable?), including system-generated
  # overtime, not just manager-submitted bonuses. Mirrors
  # Payroll::DeductionWaiver, except cancellation is terminal — there is no
  # "restore" action, matching the required UI: once cancelled, the
  # "إلغاء" action never appears again for that row.
  #
  # The underlying PayrollAdjustment (the bonus's source of truth) is NEVER
  # modified — the cancellation lives only at the payroll layer, exactly like
  # the deduction waiver layer. A cancelled addition is excluded from the
  # entry's payable totals (net salary falls accordingly) but stays visible
  # and clearly marked "ملغي".
  class AdditionCanceller
    Result = Struct.new(:success, :line_item, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(line_item:, actor:, reason: nil)
      new(line_item: line_item, actor: actor, reason: reason).call
    end

    def initialize(line_item:, actor:, reason:)
      @line_item = line_item
      @actor     = actor
      @reason    = reason.to_s.strip.presence
    end

    def call
      return err(I18n.t("payroll.addition_cancellation.errors.permission")) unless @actor.can?(:manage_payroll_addition_cancellations)

      period = @line_item.payroll_entry.payroll_period
      return err(I18n.t("payroll.addition_cancellation.errors.locked")) unless period&.editable?
      return err(I18n.t("payroll.addition_cancellation.errors.not_cancellable")) unless @line_item.addition_cancellable?
      return err(I18n.t("payroll.addition_cancellation.errors.already_cancelled")) if @line_item.addition_cancelled?

      apply!(
        addition_cancelled:           true,
        addition_cancellation_reason: @reason,
        addition_cancelled_by:        @actor,
        addition_cancelled_at:        Time.current
      )
      write_audit
      Result.new(success: true, line_item: @line_item)
    rescue => e
      Rails.logger.error("[Payroll::AdditionCanceller] line_item=#{@line_item.id} failed: #{e.message}")
      err(e.message)
    end

    private

    def apply!(attrs)
      ActiveRecord::Base.transaction do
        @line_item.update!(attrs)
        @line_item.payroll_entry.recalculate_totals!
      end
    end

    def write_audit
      entry = @line_item.payroll_entry
      PayrollAuditLog.create!(
        payroll_period: entry.payroll_period,
        actor:          @actor,
        action_type:    "addition_cancelled",
        metadata:       {
          payroll_period_id: entry.payroll_period_id,
          payroll_entry_id:  entry.id,
          addition_id:       @line_item.id,
          employee_id:       entry.user_id,
          amount:            @line_item.amount.abs.to_f,
          old_state:         "active",
          new_state:         "cancelled",
          reason:            @reason,
          actor_id:          @actor.id,
          timestamp:         Time.current.iso8601
        }.to_json
      )
    rescue => e
      Rails.logger.error("[PayrollAuditLog] addition_cancelled write failed: #{e.message}")
    end

    def err(msg)
      Result.new(success: false, error: msg)
    end
  end
end
