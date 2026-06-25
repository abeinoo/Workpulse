module Finance
  # Records a cash deposit against a depositor-type handover.
  # The till_handover must be: depositor type, accepted, and belong to actor.
  class TillDepositRecorder
    include AuditLoggable

    Result = Struct.new(:ok, :deposit, :error, keyword_init: true) { def ok? = ok }

    def initialize(till_handover, actor:, params:)
      @till_handover = till_handover
      @actor         = actor
      @params        = params
    end

    def call
      unless @till_handover.depositor? && @till_handover.accepted?
        return Result.new(ok: false, error: I18n.t("till_deposits.errors.handover_not_depositor"))
      end

      unless @till_handover.from_user_id == @actor.id
        return Result.new(ok: false, error: I18n.t("till_deposits.errors.not_depositor"))
      end

      ActiveRecord::Base.transaction do
        deposit = @till_handover.deposits.create!(
          payment_method_id: @params[:payment_method_id],
          deposited_by:      @actor,
          amount:            @params[:amount].to_d,
          deposited_at:      @params[:deposited_at] || Time.current,
          reference:         @params[:reference],
          notes:             @params[:notes]
        )
        log_audit(
          actor:     @actor,
          auditable: deposit,
          action:    "create",
          metadata:  { amount: deposit.amount.to_s,
                       payment_method_id: deposit.payment_method_id }
        )
        Result.new(ok: true, deposit: deposit)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
