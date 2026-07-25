module Finance
  module BankDisputes
    # Opens a new BankDispute case, anchored either:
    #   - on an already-recorded TillDeposit whose bank-side transaction never
    #     landed (POS deducted the money but the deposit didn't clear), or
    #   - directly on a DailyReconciliation, reported before any TillDeposit
    #     exists at all (cash went into an ATM/POS machine, the card was
    #     debited, but the money never reached the bank — the "Report ATM
    #     Deposit Problem" action from the Record Deposit dialog).
    # Exactly one of till_deposit_id/daily_reconciliation_id must be given.
    class Creator
      include AuditLoggable

      Result = Struct.new(:ok, :dispute, :error, keyword_init: true) { def ok? = ok }

      def initialize(actor:, till_deposit_id: nil, daily_reconciliation_id: nil, params: {})
        @actor                   = actor
        @till_deposit_id         = till_deposit_id
        @daily_reconciliation_id = daily_reconciliation_id
        @params                  = params
      end

      def call
        if @till_deposit_id
          deposit = TillDeposit
                      .joins(:daily_reconciliation)
                      .where(daily_reconciliations: { business_id: @actor.business_id })
                      .find(@till_deposit_id)
          dr   = deposit.daily_reconciliation
          kind = "missing_from_bank"
        else
          dr      = DailyReconciliation.where(business_id: @actor.business_id).find(@daily_reconciliation_id)
          deposit = nil
          kind    = "atm_deposit_failure"
        end

        ActiveRecord::Base.transaction do
          dispute = BankDispute.create!(
            till_deposit:         deposit,
            daily_reconciliation: deposit ? nil : dr,
            business:             dr.business,
            branch:               dr.branch,
            kind:                 kind,
            opened_by:            @actor,
            opened_at:            Time.current,
            status:               "new",
            transaction_date:     @params[:transaction_date],
            transaction_time:     @params[:transaction_time],
            amount:               @params[:amount],
            bank_name:            @params[:bank_name],
            terminal_id:          @params[:terminal_id],
            merchant_id:          @params[:merchant_id],
            card_last4:           @params[:card_last4],
            reference_number:     @params[:reference_number],
            stan:                 @params[:stan],
            authorization_code:   @params[:authorization_code],
            bank_ticket_number:   @params[:bank_ticket_number],
            atm_location:         @params[:atm_location],
            notes:                @params[:notes]
          )

          dispute.photos.attach(@params[:photos]) if @params[:photos].present?

          log_audit(actor: @actor, auditable: dispute, action: kind == "atm_deposit_failure" ? "reported" : "opened")

          Result.new(ok: true, dispute: dispute)
        end
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
