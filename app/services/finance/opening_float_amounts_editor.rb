module Finance
  # Saves override amounts on a waiting_for_opening DailyReconciliation without
  # accepting the till.  Used when a manager spots a mistake in the declared
  # opening balance before the next cashier has received it.
  #
  # Stores a JSONB array on `daily_reconciliation.opening_float_override_amounts`.
  # OpeningFloatReceiver reads this column at acceptance time and uses the
  # overrides instead of copying from the source handover verbatim.
  #
  # The original next_day_amounts on the source handover are never mutated.
  class OpeningFloatAmountsEditor
    include AuditLoggable

    Result = Struct.new(:ok, :error, keyword_init: true) { def ok? = ok }

    # amounts: hash of source_amount_id (string/integer) =>
    #          { "collected_amount" => "...", "refund_amount" => "..." }
    def initialize(daily_reconciliation_id:, actor:, amounts:)
      @dr_id   = daily_reconciliation_id
      @actor   = actor
      @amounts = amounts.to_h
    end

    def call
      @dr = DailyReconciliation
              .where(business_id: @actor.business_id)
              .includes(opening_float_source_handover: { amounts: :payment_method })
              .find(@dr_id)

      return err(:not_waiting) unless @dr.blocked_by_opening_float?

      source = @dr.opening_float_source_handover
      return err(:no_source) unless source

      indexed = source.amounts.next_day.includes(:payment_method).index_by { |a| a.id.to_s }

      overrides = []
      @amounts.each do |aid, attrs|
        nda = indexed[aid.to_s]
        next unless nda
        overrides << {
          "source_amount_id"    => nda.id,
          "payment_method_id"   => nda.payment_method_id,
          "payment_method_name" => nda.payment_method_name,
          "collected_amount"    => attrs["collected_amount"].to_d.to_s("F"),
          "refund_amount"       => attrs["refund_amount"].to_d.to_s("F")
        }
      end

      return err(:no_valid_amounts) if overrides.empty?

      @dr.update!(opening_float_override_amounts: overrides)

      log_audit(
        actor:     @actor,
        auditable: @dr,
        action:    "opening_float_amounts_edited",
        metadata:  {
          source_handover_id: source.id,
          override_count:     overrides.size
        }
      )

      Result.new(ok: true)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotFound
      Result.new(ok: false, error: I18n.t("finance.daily_reconciliations.errors.correction_not_found"))
    end

    private

    def err(key) = Result.new(ok: false, error: I18n.t("finance.daily_reconciliations.errors.opening_float_edit_#{key}"))
  end
end
