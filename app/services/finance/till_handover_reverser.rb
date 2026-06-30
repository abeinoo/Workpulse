module Finance
  # Reverses an accepted peer handover by creating a new compensating TillHandover
  # that returns custody from the original receiver back to the original sender.
  #
  # The original handover is stamped immutably.  Neither record is ever modified
  # again.  The reversal handover is auto-accepted (administrative event; no
  # physical pending step) and immediately updates till_session.current_holder.
  #
  # Guard conditions (all enforced in service + policy):
  #   - handover must be accepted
  #   - handover must be a peer transfer (not a self-deposit close record)
  #   - handover must not already be reversed
  #   - handover must not itself be a reversal record
  #   - DR must not be verified
  #   - receiver must not have started working (sent or deposited anything on this DR)
  class TillHandoverReverser
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    REVERSAL_REASON_CODES = %w[
      wrong_cash_amount
      wrong_payment_amounts
      wrong_employee
      duplicate_handover
      other
    ].freeze

    def initialize(handover_id:, actor:, reason_code:, reason_notes: nil)
      @handover_id  = handover_id
      @actor        = actor
      @reason_code  = reason_code
      @reason_notes = reason_notes
    end

    def call
      @handover = TillHandover
                    .joins(:daily_reconciliation)
                    .where(daily_reconciliations: { business_id: @actor.business_id })
                    .includes(:amounts, daily_reconciliation: :till_session)
                    .find(@handover_id)

      validate!
      perform
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    end

    private

    def validate!
      raise ArgumentError, I18n.t("till_handovers.errors.not_accepted")       unless @handover.accepted?
      raise ArgumentError, I18n.t("till_handovers.errors.self_deposit_immutable") if @handover.self_deposit?
      raise ArgumentError, I18n.t("till_handovers.errors.already_reversed")   if @handover.reversed?
      raise ArgumentError, I18n.t("till_handovers.errors.cannot_reverse_reversal") if @handover.reversal?
      raise ArgumentError, I18n.t("till_handovers.errors.dr_verified")        if @handover.daily_reconciliation.verified?
      raise ArgumentError, I18n.t("till_handovers.errors.receiver_started_working") if receiver_started_working?
      raise ArgumentError, I18n.t("till_handovers.errors.invalid_reason_code") unless REVERSAL_REASON_CODES.include?(@reason_code)
      raise ArgumentError, I18n.t("till_handovers.errors.reason_notes_required") if @reason_code == "other" && @reason_notes.blank?
    end

    def perform
      reversal = nil

      ActiveRecord::Base.transaction do
        dr      = @handover.daily_reconciliation
        session = dr.till_session

        # Stamp the original as reversed — immutably.
        @handover.update!(
          reversed_at:     Time.current,
          reversed_by:     @actor,
          reversal_reason: formatted_reason
        )

        # Create the compensating handover (receiver → original sender).
        reversal = TillHandover.create!(
          daily_reconciliation:   dr,
          from_user:              @handover.to_user,
          to_user:                @handover.from_user,
          reversal_of_handover:   @handover,
          self_deposit:           false,
          accepted_at:            Time.current   # auto-accepted; admin event
        )

        # Copy the original amounts into the reversal so the ledger balances.
        @handover.amounts.each do |amt|
          reversal.amounts.create!(
            payment_method_id: amt.payment_method_id,
            collected_amount:  amt.collected_amount,
            refund_amount:     amt.refund_amount
          )
        end

        # Revert custody.
        session.update!(current_holder: @handover.from_user)

        log_audit(
          actor:     @actor,
          auditable: @handover,
          action:    "reversed",
          metadata:  {
            reversal_handover_id: reversal.id,
            reason_code:          @reason_code,
            reason_notes:         @reason_notes
          }
        )
      end

      Result.new(ok: true, record: reversal)
    end

    def receiver_started_working?
      dr = @handover.daily_reconciliation
      dr.till_handovers
        .where(from_user_id: @handover.to_user_id)
        .where.not(id: @handover.id)
        .exists?
    end

    def formatted_reason
      if @reason_notes.present?
        "#{@reason_code}: #{@reason_notes}"
      else
        @reason_code
      end
    end
  end
end
