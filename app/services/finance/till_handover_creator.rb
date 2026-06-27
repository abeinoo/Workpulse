module Finance
  # Creates a TillHandover rooted on a DailyReconciliation.
  #
  # Two modes:
  #   hand_to_colleague — records a handover to a named recipient who must accept.
  #                       Business date is stamped; session stays open.
  #   self_deposit      — no recipient. The accounting day is closed immediately;
  #                       the actor becomes the depositor.
  #
  # The DailyReconciliation must be open. All business workflows originate here
  # — no code should call TillSession directly to initiate a handover.
  class TillHandoverCreator
    include AuditLoggable

    Result = Struct.new(:ok, :handover, :error, keyword_init: true) { def ok? = ok }

    def initialize(actor:, daily_reconciliation:, params:)
      @actor                = actor
      @daily_reconciliation = daily_reconciliation
      @business             = daily_reconciliation.business
      @params               = params
      @fresha_date          = BusinessDay.current(context: @business)
    end

    def call
      ActiveRecord::Base.transaction do
        session = @daily_reconciliation.till_session
        raise ArgumentError, I18n.t("till_handovers.errors.no_open_session") unless session

        validate_no_pending_outgoing!
        validate_actor_is_holder!(session) if self_deposit?
        validate_minimum_amounts!
        validate_payment_methods!
        validate_recipient! unless self_deposit?
        validate_depositor! if self_deposit?

        handover = TillHandover.create!(
          daily_reconciliation: @daily_reconciliation,
          from_user:            @actor,
          to_user_id:           self_deposit? ? nil : @params[:to_user_id],
          self_deposit:         self_deposit?,
          fresha_date:          @fresha_date,
          from_notes:           @params[:notes]
        )

        build_amounts(handover, "operational", @params[:amounts])
        build_amounts(handover, "next_day", @params[:next_day_amounts]) if next_day_amounts_present?

        close_day!(session, handover) if self_deposit?

        log_audit(actor: @actor, auditable: handover, action: "create",
                  metadata: { daily_reconciliation_id: @daily_reconciliation.id,
                               self_deposit: self_deposit? })

        Result.new(ok: true, handover: handover)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    end

    private

    def self_deposit?
      @self_deposit ||= @params[:self_deposit].to_s.in?(%w[1 true])
    end

    def next_day_amounts_present?
      (@params[:next_day_amounts] || {}).values.any? { |a|
        a[:collected_amount].to_d > 0 || a[:refund_amount].to_d > 0
      }
    end

    def validate_no_pending_outgoing!
      pending = @daily_reconciliation.till_handovers
                                     .pending
                                     .find_by(from_user: @actor, self_deposit: false)
      raise ArgumentError, I18n.t("till_handovers.errors.pending_exists") if pending
    end

    def validate_actor_is_holder!(session)
      return if session.current_holder.nil?
      return if session.current_holder == @actor
      raise ArgumentError, I18n.t("till_handovers.errors.cannot_close_session")
    end

    def validate_minimum_amounts!
      last_received = @daily_reconciliation.till_handovers
                                           .accepted
                                           .where(to_user: @actor)
                                           .order(accepted_at: :desc)
                                           .includes(amounts: :payment_method)
                                           .first
      return unless last_received

      received_by_pm = last_received.amounts.operational.index_by { |a| a.payment_method_id.to_s }
      errors = []

      (@params[:amounts] || {}).each do |pm_id, attrs|
        received = received_by_pm[pm_id.to_s]
        next unless received

        submitted_collected = attrs[:collected_amount].to_d
        submitted_refund    = attrs[:refund_amount].to_d

        if submitted_collected < received.collected_amount
          errors << I18n.t("till_handovers.errors.below_minimum_collected",
                           pm: received.payment_method_name,
                           min: received.collected_amount)
        end

        if submitted_refund < received.refund_amount
          errors << I18n.t("till_handovers.errors.below_minimum_refund",
                           pm: received.payment_method_name,
                           min: received.refund_amount)
        end
      end

      raise ArgumentError, errors.join(". ") if errors.any?
    end

    def validate_recipient!
      unless @business.users.active.exists?(@params[:to_user_id])
        raise ArgumentError, I18n.t("till_handovers.errors.invalid_recipient")
      end
      recipient = @business.users.find(@params[:to_user_id])
      unless recipient.can?(:accept_till_handover)
        raise ArgumentError, I18n.t("till_handovers.errors.recipient_cannot_accept")
      end
    end

    def validate_depositor!
      type = @params[:depositor_type].to_s
      raise ArgumentError, I18n.t("till_handovers.errors.depositor_required") if type.blank?
      return if type == "self"

      id = @params[:depositor_id].to_s
      raise ArgumentError, I18n.t("till_handovers.errors.depositor_required") if id.blank?

      user = @business.users.active.find_by(id: id)
      raise ArgumentError, I18n.t("till_handovers.errors.depositor_required") unless user
      raise ArgumentError, I18n.t("till_handovers.errors.invalid_depositor_permission") unless user.can?(:create_till_deposit)
    end

    def validate_payment_methods!
      all_ids = (Array((@params[:amounts] || {}).keys) +
                 Array((@params[:next_day_amounts] || {}).keys)).map(&:to_s).uniq
      return if all_ids.empty?
      valid_ids = PaymentMethod.for_business(@business).active.pluck(:id).map(&:to_s)
      unless (all_ids - valid_ids).empty?
        raise ArgumentError, I18n.t("till_handovers.errors.invalid_payment_method")
      end
    end

    def build_amounts(handover, kind, amounts_hash)
      return if amounts_hash.blank?
      payment_methods = PaymentMethod.for_business(@business).active.index_by { |pm| pm.id.to_s }

      amounts_hash.each do |pm_id, attrs|
        pm = payment_methods[pm_id.to_s]
        next unless pm

        if kind == "next_day"
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
        else
          handover.amounts.create!(
            payment_method:      pm,
            payment_method_name: pm.display_name,
            collected_amount:    attrs[:collected_amount].to_d,
            refund_amount:       attrs[:refund_amount].to_d,
            kind:                "operational"
          )
        end
      end
    end

    # Closes the accounting day: stamps DR state, session details, then persists
    # the per-employee reconciliation summary snapshot.
    #
    # Depositor assignment:
    #   - "self"  → actor becomes depositor immediately.
    #   - "other" → actor remains depositor; a DepositResponsibilityTransfer is
    #               created and the named employee must explicitly accept before
    #               the depositor_id changes to them.
    def close_day!(session, handover)
      now = Time.current

      handover.amounts.operational.each do |ha|
        @daily_reconciliation.session_amounts.upsert_by_payment_method(ha.payment_method,
          collected_amount: ha.collected_amount,
          refund_amount:    ha.refund_amount)
      end

      @daily_reconciliation.update!(
        state:         "closed",
        closed_at:     now,
        business_date: @fresha_date
      )

      session.update!(closed_by: @actor, depositor: @actor)

      if @params[:depositor_type] == "other"
        transfer = DepositResponsibilityTransfer.create!(
          daily_reconciliation: @daily_reconciliation,
          from_user:            @actor,
          to_user_id:           @params[:depositor_id].to_i
        )
        log_audit(actor: @actor, auditable: transfer, action: "assign",
                  metadata: { daily_reconciliation_id: @daily_reconciliation.id,
                               to_user_id:             transfer.to_user_id })
      end

      Finance::EmployeeReconciliationSummarizer.new(@daily_reconciliation).persist!
    end
  end
end
