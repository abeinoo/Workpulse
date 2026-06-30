module Finance
  # Records a documentary FinancialAdjustment on an accepted TillHandover.
  #
  # An adjustment does NOT change any financial records or custody state.
  # It captures:
  #   - what actually happened (before_data — snapshot of the original amounts)
  #   - what should have happened (after_data — manager-supplied correction)
  #   - who approved it, why, and when
  #
  # Reports and reconciliation tooling may choose to display original or adjusted
  # values; the historical TillHandover and its TillHandoverAmounts remain immutable.
  #
  # Guard conditions:
  #   - handover must be accepted
  #   - handover must be a peer transfer (not a self-deposit)
  #   - DR must not be verified
  #   - reason_code must be from the allowed set
  #   - notes must be present (minimum 10 characters — enforced by model)
  #   - after_data must describe at least one payment method
  class TillHandoverAdjuster
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    REASON_CODES = %w[
      wrong_amounts
      wrong_employee
      duplicate_handover
      system_error
      other
    ].freeze

    def initialize(handover:, actor:, reason_code:, notes:, after_data:)
      @handover     = handover
      @actor        = actor
      @reason_code  = reason_code
      @notes        = notes
      @after_data   = after_data
    end

    def call
      validate!
      perform
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    end

    private

    def validate!
      raise ArgumentError, I18n.t("till_handovers.errors.not_accepted")           unless @handover.accepted?
      raise ArgumentError, I18n.t("till_handovers.errors.self_deposit_immutable") if @handover.self_deposit?
      raise ArgumentError, I18n.t("till_handovers.errors.dr_verified")            if @handover.daily_reconciliation.verified?
      raise ArgumentError, I18n.t("till_handovers.errors.invalid_reason_code")    unless REASON_CODES.include?(@reason_code)
      raise ArgumentError, I18n.t("till_handovers.errors.after_data_required")    if Array(@after_data).empty?
    end

    def perform
      adjustment = nil

      ActiveRecord::Base.transaction do
        adjustment = FinancialAdjustment.create!(
          adjustable:   @handover,
          business:     @handover.business,
          actor:        @actor,
          reason_code:  @reason_code,
          notes:        @notes,
          before_data:  snapshot_amounts(@handover.amounts),
          after_data:   @after_data
        )

        log_audit(
          actor:     @actor,
          auditable: @handover,
          action:    "adjusted",
          metadata:  {
            adjustment_id: adjustment.id,
            reason_code:   @reason_code
          }
        )
      end

      Result.new(ok: true, record: adjustment)
    end

    def snapshot_amounts(amounts)
      amounts.map do |a|
        {
          payment_method_id:   a.payment_method_id,
          payment_method_name: a.payment_method.name,
          collected_amount:    a.collected_amount.to_s,
          refund_amount:       a.refund_amount.to_s
        }
      end
    end
  end
end
