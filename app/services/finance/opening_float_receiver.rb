module Finance
  # Receives the opening float for a waiting_for_opening DailyReconciliation.
  #
  # Creates the first TillHandover of the new business day:
  #   from_user  = previous day's final holder (source handover's from_user)
  #   to_user    = receiving cashier (actor)
  #   accepted_at = now (auto-accepted — no pending step needed)
  #   amounts    = the next_day amounts from the source handover, copied as
  #                operational amounts on the new handover
  #
  # After the handover is created the DR transitions to `open` and the
  # TillSession's current_holder is set to the receiving cashier.
  #
  # This is the sole authorised direct write to TillHandover outside of
  # TillHandoverCreator.  It bootstraps day N+1 from day N's float — an
  # operation that cannot go through TillHandoverCreator because the DR is
  # not yet open at that point.
  class OpeningFloatReceiver
    include AuditLoggable

    Result = Struct.new(:ok, :handover, :error, keyword_init: true) { def ok? = ok }

    def initialize(daily_reconciliation_id:, actor:)
      @dr_id = daily_reconciliation_id
      @actor = actor
    end

    def call
      @dr = DailyReconciliation
              .where(business_id: @actor.business_id)
              .includes(:till_session, opening_float_source_handover: :from_user)
              .find(@dr_id)

      unless @dr.blocked_by_opening_float?
        return err("not_waiting")
      end

      unless @dr.opening_float_receivable?
        return err("not_yet")
      end

      source = @dr.opening_float_source_handover
      unless source
        return err("no_source_handover")
      end

      next_day_amounts = source.amounts.next_day.includes(:payment_method).to_a
      if next_day_amounts.empty?
        return err("no_amounts")
      end

      ActiveRecord::Base.transaction do
        now = Time.current

        handover = TillHandover.create!(
          daily_reconciliation: @dr,
          from_user:            source.from_user,
          to_user:              @actor,
          self_deposit:         false,
          fresha_date:          @dr.business_date,
          accepted_at:          now,
          from_notes:           nil
        )

        # If a manager saved override amounts before acceptance, apply them.
        # Overrides are keyed by source_amount_id; any unmatched source amounts
        # fall back to their original values so partial overrides are safe.
        override_map = (@dr.opening_float_override_amounts || [])
                         .index_by { |o| o["source_amount_id"].to_i }
        amounts_overridden = override_map.any?

        next_day_amounts.each do |nda|
          override = override_map[nda.id]
          handover.amounts.create!(
            payment_method:      nda.payment_method,
            payment_method_name: nda.payment_method_name,
            collected_amount:    override ? override["collected_amount"].to_d : nda.collected_amount,
            refund_amount:       override ? override["refund_amount"].to_d    : nda.refund_amount,
            kind:                "operational"
          )
        end

        # Keep opening_float_source_handover set — it is used by the audit
        # timeline on this DR to detect the opening_float_received event.
        # The waiting_for_opening? predicate returns false once state is open,
        # so the receive card will no longer render.
        @dr.update!(state: "open")

        @dr.till_session.update!(current_holder: @actor)

        log_audit(
          actor:     @actor,
          auditable: @dr,
          action:    "opening_float_received",
          metadata:  {
            source_handover_id: source.id,
            new_handover_id:    handover.id,
            from_user_id:       source.from_user_id,
            amounts_overridden: amounts_overridden
          }
        )

        Result.new(ok: true, handover: handover)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def err(key) = Result.new(ok: false, error: I18n.t("finance.daily_reconciliations.errors.opening_float_#{key}"))
  end
end
