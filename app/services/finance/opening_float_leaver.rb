module Finance
  # Records a cashier's intent to leave a float in the drawer for the next
  # business day.  This is a standalone action that happens *after* the day is
  # closed — it is separate from closing and may be performed by a different
  # employee than the one who closed the session.
  #
  # Creates a self-deposit TillHandover flagged as `opening_float_declaration`
  # carrying `next_day` amounts, then delegates to NextDayDrPreparer to create
  # the waiting-for-opening DR for the next business day.
  #
  # Idempotent at the DR level: if a declaration already exists for today's DR,
  # returns an error rather than creating a duplicate.
  class OpeningFloatLeaver
    include AuditLoggable

    Result = Struct.new(:ok, :daily_reconciliation, :error, keyword_init: true) { def ok? = ok }

    def initialize(actor:, daily_reconciliation_id:, amounts:)
      @actor   = actor
      @dr_id   = daily_reconciliation_id
      @amounts = amounts || {}
    end

    def call
      @dr = DailyReconciliation
              .where(business_id: @actor.business_id)
              .includes(:business, :branch, :till_session)
              .find(@dr_id)

      unless @dr.closed? || @dr.deposited?
        raise ArgumentError, I18n.t("opening_floats.errors.dr_not_closed")
      end
      raise ArgumentError, I18n.t("opening_floats.errors.already_prepared") if already_prepared?
      raise ArgumentError, I18n.t("opening_floats.errors.no_amounts")       unless amounts_present?

      validate_payment_methods!

      ActiveRecord::Base.transaction do
        handover = @dr.till_handovers.create!(
          from_user:                  @actor,
          to_user:                    nil,
          self_deposit:               true,
          opening_float_declaration:  true,
          fresha_date:                @dr.business_date
        )

        build_next_day_amounts(handover)

        result = Finance::NextDayDrPreparer.new(
          branch:          @dr.branch,
          business:        @dr.business,
          actor:           @actor,
          source_handover: handover
        ).call

        raise ArgumentError, result.error unless result.ok?

        Result.new(ok: true, daily_reconciliation: result.daily_reconciliation)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    end

    private

    def already_prepared?
      @dr.till_handovers.where(opening_float_declaration: true).exists?
    end

    def amounts_present?
      @amounts.values.any? { |a|
        a[:collected_amount].to_d > 0 || a[:refund_amount].to_d > 0
      }
    end

    def validate_payment_methods!
      pm_ids    = @amounts.keys.map(&:to_s)
      valid_ids = PaymentMethod.for_business(@dr.business).active.pluck(:id).map(&:to_s)
      unless (pm_ids - valid_ids).empty?
        raise ArgumentError, I18n.t("opening_floats.errors.invalid_payment_method")
      end
    end

    def build_next_day_amounts(handover)
      payment_methods = PaymentMethod.for_business(@dr.business).active.index_by { |pm| pm.id.to_s }

      @amounts.each do |pm_id, attrs|
        pm = payment_methods[pm_id.to_s]
        next unless pm

        amount = attrs[:collected_amount].to_d
        refund = attrs[:refund_amount].to_d
        next if amount.zero? && refund.zero?

        handover.amounts.create!(
          payment_method:      pm,
          payment_method_name: pm.display_name,
          collected_amount:    amount,
          refund_amount:       refund,
          kind:                "next_day"
        )
      end
    end
  end
end
