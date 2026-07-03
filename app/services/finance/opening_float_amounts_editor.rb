module Finance
  # Saves override amounts on a waiting_for_opening DailyReconciliation without
  # accepting the till.  Used when a manager spots a mistake in the declared
  # opening balance before the next cashier has received it.
  #
  # Stores a JSONB array on `daily_reconciliation.opening_float_override_amounts`.
  # Each entry is keyed by payment_method_id, not by source_amount_id, so the
  # manager can add payment methods that were absent from the original declaration.
  #
  # OpeningFloatReceiver treats the override list as the complete desired state
  # when any overrides are present, creating handover amounts only for entries
  # with a positive collected_amount.
  #
  # The original next_day_amounts on the source handover are never mutated.
  class OpeningFloatAmountsEditor
    include AuditLoggable

    Result = Struct.new(:ok, :error, keyword_init: true) { def ok? = ok }

    # amounts: hash of payment_method_id (string/integer) =>
    #          { "collected_amount" => "...", "refund_amount" => "..." }
    def initialize(daily_reconciliation_id:, actor:, amounts:)
      @dr_id   = daily_reconciliation_id
      @actor   = actor
      @amounts = amounts.to_h
    end

    def call
      @dr = DailyReconciliation
              .where(business_id: @actor.business_id)
              .includes(opening_float_source_handover: :amounts)
              .find(@dr_id)

      return err(:not_waiting) unless @dr.blocked_by_opening_float?

      source = @dr.opening_float_source_handover
      return err(:no_source) unless source

      # Index source next_day amounts by payment_method_id for source_amount_id lookup.
      source_by_pm_id = source.amounts.next_day.index_by(&:payment_method_id)

      # Load all active payment methods for this business for validation.
      active_pms = PaymentMethod.active
                                .where(business_id: @actor.business_id)
                                .index_by(&:id)

      overrides = []
      @amounts.each do |pm_id_str, attrs|
        pm = active_pms[pm_id_str.to_i]
        next unless pm

        collected  = attrs["collected_amount"].to_d
        refund     = attrs["refund_amount"].to_d
        source_amt = source_by_pm_id[pm.id]

        # Skip zero-amount entries for PMs not in the source — they add nothing.
        # For source PMs, save even when zero so the receiver knows to exclude them.
        next if collected.zero? && refund.zero? && source_amt.nil?

        overrides << {
          "payment_method_id"   => pm.id,
          "payment_method_name" => pm.name,
          "collected_amount"    => collected.to_s("F"),
          "refund_amount"       => refund.to_s("F"),
          "source_amount_id"    => source_amt&.id
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
