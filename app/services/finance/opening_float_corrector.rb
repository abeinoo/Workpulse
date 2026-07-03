module Finance
  # Corrects the opening float for a DailyReconciliation that is already open.
  #
  # Supersedes the original opening-float handover (preserving it in the audit trail)
  # and creates a new correction handover with the corrected amounts.  Both records are
  # linked via corrects_handover_id on the new handover.
  #
  # Constraints:
  #   - DR must be open (not closed, deposited, or verified).
  #   - Opening float must have been received (DR not in waiting_for_opening state).
  #   - The original opening float handover must not already be superseded.
  #   - correction_reason is mandatory.
  class OpeningFloatCorrector
    include AuditLoggable

    Result = Struct.new(:ok, :handover, :error, keyword_init: true) { def ok? = ok }

    # amounts: hash of TillHandoverAmount.id (string/integer) =>
    #          { "collected_amount" => "...", "refund_amount" => "..." }
    def initialize(daily_reconciliation_id:, actor:, amounts:, correction_reason:)
      @dr_id             = daily_reconciliation_id
      @actor             = actor
      @amounts           = amounts.to_h
      @correction_reason = correction_reason.to_s.strip
    end

    def call
      return err(:reason_blank) if @correction_reason.blank?

      @dr = DailyReconciliation
              .where(business_id: @actor.business_id)
              .find(@dr_id)

      return err(:not_open) unless @dr.open?

      original = find_opening_receipt_handover
      return err(:no_opening_float) unless original
      return err(:already_corrected) if original.superseded?

      ActiveRecord::Base.transaction do
        now = Time.current

        original.update!(
          superseded_at:     now,
          superseded_by:     @actor,
          correction_reason: @correction_reason
        )

        correction = TillHandover.create!(
          daily_reconciliation: @dr,
          from_user:            original.from_user,
          to_user:              original.to_user,
          self_deposit:         false,
          fresha_date:          @dr.business_date,
          accepted_at:          now,
          corrects_handover:    original,
          from_notes:           @correction_reason
        )

        # Index original amounts by ID for safe lookup — amounts not belonging
        # to the original handover are silently skipped.
        original_amounts = original.amounts.operational.includes(:payment_method).index_by { |a| a.id.to_s }

        @amounts.each do |amount_id, attrs|
          source = original_amounts[amount_id.to_s]
          next unless source

          correction.amounts.create!(
            payment_method:      source.payment_method,
            payment_method_name: source.payment_method_name,
            collected_amount:    attrs["collected_amount"].to_d,
            refund_amount:       attrs["refund_amount"].to_d,
            kind:                "operational"
          )
        end

        log_audit(
          actor:     @actor,
          auditable: @dr,
          action:    "opening_float_corrected",
          metadata:  {
            original_handover_id:   original.id,
            correction_handover_id: correction.id,
            correction_reason:      @correction_reason
          }
        )

        Result.new(ok: true, handover: correction)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotFound
      Result.new(ok: false, error: I18n.t("finance.daily_reconciliations.errors.correction_not_found"))
    end

    private

    def find_opening_receipt_handover
      return nil unless @dr.opening_float_source_handover_id.present?

      @dr.till_handovers
         .peer
         .accepted
         .includes(:from_user, amounts: :payment_method)
         .order(:created_at)
         .first
    end

    def err(key) = Result.new(ok: false, error: I18n.t("finance.daily_reconciliations.errors.correction_#{key}"))
  end
end
