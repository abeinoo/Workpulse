module Payroll
  # Edits an approved PayrollAdjustment (type, amount, reason, payroll period).
  #
  # Editing reverts the adjustment to pending_review so it cannot affect payroll
  # until re-approved. The edit is recorded in PayrollAdjustmentEdit for a full
  # audit trail including old/new period when the period changes.
  #
  # Guards:
  #   - Adjustment must currently be approved.
  #   - Current period must not be finalized or paid (:period_finalized).
  #   - Target period (if changed) must not be locked (:target_period_locked).
  #   - Actor must hold edit_approved_adjustments (enforced by policy before calling).
  #
  # Period change behaviour: when period_key selects a different month/year, the
  # existing PayrollLineItem is destroyed from the old entry (and its totals
  # recalculated). AdjustmentApplier creates a fresh line_item in the new entry
  # when the adjustment is re-approved.
  class AdjustmentEditor
    Result = Struct.new(:ok, :record, :error, keyword_init: true) do
      def ok? = ok
      def period_finalized?    = error == :period_finalized
      def target_period_locked? = error == :target_period_locked
    end

    def self.call(adjustment_id:, actor:, params:)
      new(adjustment_id: adjustment_id, actor: actor, params: params).call
    end

    def initialize(adjustment_id:, actor:, params:)
      @adjustment_id = adjustment_id
      @actor         = actor
      @params        = params
    end

    def call
      @adjustment = PayrollAdjustment
        .where(business: @actor.business)
        .find(@adjustment_id)

      return Result.new(ok: false, error: :not_approved) unless @adjustment.approved?

      if current_period_finalized?
        return Result.new(ok: false, error: :period_finalized, record: @adjustment)
      end

      if target_period_locked?
        return Result.new(ok: false, error: :target_period_locked, record: @adjustment)
      end

      ActiveRecord::Base.transaction do
        snapshot = build_snapshot

        @adjustment.assign_attributes(permitted_params)

        raise ActiveRecord::RecordInvalid, @adjustment unless @adjustment.valid?

        period_changed = @adjustment.period_month != snapshot[:period_month] ||
                         @adjustment.period_year  != snapshot[:period_year]

        @adjustment.update_columns(
          adjustment_type:   @adjustment.adjustment_type,
          amount:            @adjustment.amount,
          reason:            @adjustment.reason,
          period_month:      @adjustment.period_month,
          period_year:       @adjustment.period_year,
          payroll_period_id: period_changed ? resolved_target_period&.id : @adjustment.payroll_period_id,
          review_status:     "pending_review",
          approved_by_id:    nil,
          approved_at:       nil,
          reviewed_by_id:    nil,
          reviewed_at:       nil
        )

        PayrollAdjustmentEdit.create!(
          payroll_adjustment:  @adjustment,
          business:            @actor.business,
          edited_by:           @actor,
          old_adjustment_type: snapshot[:adjustment_type],
          old_amount:          snapshot[:amount],
          old_reason:          snapshot[:reason],
          old_period_month:    snapshot[:period_month],
          old_period_year:     snapshot[:period_year],
          new_adjustment_type: @adjustment.adjustment_type,
          new_amount:          @adjustment.amount,
          new_reason:          @adjustment.reason,
          new_period_month:    @adjustment.period_month,
          new_period_year:     @adjustment.period_year
        )

        reset_line_item!(period_changed: period_changed, snapshot: snapshot)

        log_audit_edit!(snapshot)

        Result.new(ok: true, record: @adjustment.reload)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, record: @adjustment, error: e.record.errors.full_messages.first)
    rescue ArgumentError => e
      Result.new(ok: false, record: @adjustment, error: e.message)
    end

    private

    def permitted_params
      base = @params.slice(:adjustment_type, :amount, :reason)
      base = base.merge(amount: base[:amount].to_d) if base[:amount].present?

      if (parsed = parsed_period_key)
        base = base.merge(period_year: parsed[:year], period_month: parsed[:month])
      end

      base
    end

    def parsed_period_key
      key = @params[:period_key].presence
      return nil unless key && key =~ /\A(\d{4})-(\d{1,2})\z/

      { year: Regexp.last_match(1).to_i, month: Regexp.last_match(2).to_i }
    end

    # Looks up — and memoizes — the PayrollPeriod record for the selected target
    # period_key. Returns nil when the target month has no PayrollPeriod yet (a
    # future month is still a valid destination; it just has no period record).
    def resolved_target_period
      return @resolved_target_period if defined?(@resolved_target_period)

      @resolved_target_period = if (parsed = parsed_period_key)
        PayrollPeriod.find_by(
          business:     @actor.business,
          period_year:  parsed[:year],
          period_month: parsed[:month]
        )
      end
    end

    def current_period_finalized?
      period = @adjustment.payroll_period ||
               PayrollPeriod.find_by(
                 business:     @actor.business,
                 period_month: @adjustment.period_month,
                 period_year:  @adjustment.period_year
               )
      period&.finalized? || period&.paid?
    end

    def target_period_locked?
      parsed = parsed_period_key
      return false unless parsed
      return false if parsed[:year] == @adjustment.period_year &&
                      parsed[:month] == @adjustment.period_month

      tp = resolved_target_period
      return false unless tp

      Adjustments::SelectablePeriods::LOCKED_STATUSES.include?(tp.status)
    end

    def build_snapshot
      {
        adjustment_type: @adjustment.adjustment_type,
        amount:          @adjustment.amount,
        reason:          @adjustment.reason,
        period_month:    @adjustment.period_month,
        period_year:     @adjustment.period_year
      }
    end

    # When the period did NOT change: demote the existing line_item to pending_review
    # so it no longer counts toward net salary until re-approved.
    #
    # When the period DID change: destroy the line_item from the old entry (and
    # recalculate that entry's totals). AdjustmentApplier will create a fresh
    # line_item in the new period's entry when the adjustment is re-approved.
    def reset_line_item!(period_changed:, snapshot:)
      li = PayrollLineItem.find_by(
        source_type: "PayrollAdjustment",
        source_id:   @adjustment.id
      )
      return unless li

      old_entry = li.payroll_entry

      if period_changed
        li.destroy!
        old_entry.recalculate_totals!
      else
        li.update!(
          item_type:     @adjustment.line_item_type,
          amount:        @adjustment.signed_amount,
          description:   @adjustment.reason,
          review_status: "pending_review"
        )
        old_entry.recalculate_totals!
      end
    end

    def log_audit_edit!(snapshot)
      # Log against the OLD period so the event lives in its natural audit trail.
      old_period = PayrollPeriod.find_by(
        business:     @actor.business,
        period_month: snapshot[:period_month],
        period_year:  snapshot[:period_year]
      )
      return unless old_period

      PayrollAuditLog.create!(
        payroll_period: old_period,
        actor:          @actor,
        action_type:    "adjustment_edited",
        metadata:       {
          adjustment_id:       @adjustment.id,
          user_id:             @adjustment.user_id,
          old_adjustment_type: snapshot[:adjustment_type],
          new_adjustment_type: @adjustment.adjustment_type,
          old_amount:          snapshot[:amount],
          new_amount:          @adjustment.amount,
          old_reason:          snapshot[:reason],
          new_reason:          @adjustment.reason,
          old_period_month:    snapshot[:period_month],
          old_period_year:     snapshot[:period_year],
          new_period_month:    @adjustment.period_month,
          new_period_year:     @adjustment.period_year,
          edited_by_id:        @actor.id
        }.to_json
      )
    rescue StandardError => e
      Rails.logger.error("AdjustmentEditor audit log failed: #{e.message}")
    end
  end
end
