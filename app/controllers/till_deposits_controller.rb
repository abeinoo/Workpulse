class TillDepositsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_deposit, only: %i[void show manual_match_modal manual_match]

  # GET /till_deposits/new?daily_reconciliation_id=:id
  #
  # Also reachable as a "correction" entry point from a voided deposit's
  # "تصحيح الإيداع" (Correct Deposit) action — payment_method_id/prefill_amount/
  # prefill_reference are passed through to pre-fill this same form with the
  # voided deposit's values. Nothing about deposit creation itself changes:
  # submitting still goes through the exact same #create action and
  # Finance::TillDepositRecorder as any other deposit, and the voided deposit
  # is never read or touched here beyond the caller copying its values into
  # the URL.
  def new
    @reconciliation  = find_depositor_reconciliation(params[:daily_reconciliation_id])
    @deposit         = TillDeposit.new(daily_reconciliation: @reconciliation)
    @payment_methods = business_payment_methods.select(&:cash_like?)
    @expected_amounts_by_pm = expected_amounts_by_pm(@reconciliation, @payment_methods)
    @open_atm_dispute_amount = @reconciliation.open_atm_dispute_amount
    @idempotency_key = SecureRandom.uuid

    @preselected_payment_method_id = params[:payment_method_id].presence&.to_i
    @prefill_amount                = params[:prefill_amount].presence
    @prefill_reference             = params[:prefill_reference].presence

    authorize @deposit
  end

  # POST /till_deposits
  def create
    @reconciliation = find_depositor_reconciliation(deposit_params[:daily_reconciliation_id])
    @deposit        = TillDeposit.new(daily_reconciliation: @reconciliation)
    authorize @deposit

    result = Finance::TillDepositRecorder.new(
      @reconciliation.id,
      actor:  current_user,
      params: deposit_params
    ).call

    if result.ok?
      notice = if result.remaining_amount
        t("till_deposits.created_with_remaining",
          remaining: ApplicationController.helpers.number_to_currency(
                       result.remaining_amount, unit: "", separator: ".", delimiter: ","))
      else
        t("till_deposits.created")
      end
      redirect_to finance_daily_reconciliation_path(result.deposit.daily_reconciliation), notice: notice
    else
      @payment_methods = business_payment_methods.select(&:cash_like?)
      @expected_amounts_by_pm = expected_amounts_by_pm(@reconciliation, @payment_methods)
      @open_atm_dispute_amount = @reconciliation.open_atm_dispute_amount
      # Preserve the same key on re-render so a retry of this exact failed
      # submission stays idempotent rather than minting a fresh one.
      @idempotency_key = deposit_params[:idempotency_key].presence || SecureRandom.uuid
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  # GET /till_deposits/:id
  #
  # The "View" counterpart for a deposit-side reconciliation row (e.g. a
  # deposit with no matching bank transaction, "Missing from Bank"). Bank
  # transactions have their own detail page (Finance::BankStatementTransactionsController#show);
  # this is the deposit-side equivalent so every row in the deposit
  # verification tables can always be opened, regardless of status.
  def show
    authorize @deposit
    @transactions = @deposit.bank_statement_transactions.includes(:bank_statement).ordered
    @audit_logs   = AuditLog.for_auditable(@deposit).includes(:actor).recent
  end

  # GET /till_deposits/:id/manual_match_modal
  def manual_match_modal
    authorize @deposit, :match?
    @unmatched_transactions = unmatched_transactions_for_manual_matching
  end

  # PATCH /till_deposits/:id/manual_match
  def manual_match
    authorize @deposit, :match?

    result = Finance::BankStatements::ManualMatcher.call_many(
      till_deposit_id:  @deposit.id,
      transaction_ids:  Array(params[:bank_statement_transaction_ids]).reject(&:blank?),
      actor:            current_user,
      notes:            params[:match_notes].presence
    )

    if result.ok?
      redirect_to till_deposit_path(@deposit), notice: t("finance.bank_statement_transactions.matched")
    else
      redirect_to till_deposit_path(@deposit), alert: result.error
    end
  end

  # PATCH /till_deposits/:id/void
  def void
    authorize @deposit

    dest = finance_daily_reconciliation_path(@deposit.daily_reconciliation)

    result = Finance::TillDepositVoider.new(
      @deposit.id,
      actor:       current_user,
      void_reason: params[:void_reason]
    ).call

    if result.ok?
      redirect_to dest, notice: t("till_deposits.voided")
    else
      redirect_to dest, alert: result.error
    end
  end

  private

  def set_deposit
    @deposit = TillDeposit
                 .joins(:daily_reconciliation)
                 .where(daily_reconciliations: { business_id: current_user.business_id })
                 .includes(:payment_method, :deposited_by, daily_reconciliation: :branch)
                 .find(params[:id])
  end

  def find_depositor_reconciliation(id)
    DailyReconciliation
      .where(business_id: current_user.business_id)
      .includes(session_amounts: :payment_method)
      .find(id)
  end

  # Returns a Hash { pm_id => expected_pending_amount } for use in the form.
  # Delegates to DailyReconciliation#remaining_by_payment_method — the same
  # source TillDepositRecorder validates against — so the dialog can never
  # display a figure the recorder would then reject.
  def expected_amounts_by_pm(reconciliation, payment_methods)
    remaining = reconciliation.remaining_by_payment_method
    payment_methods.each_with_object({}) { |pm, h| h[pm.id] = remaining[pm.id] || 0 }
  end

  def deposit_params
    params.require(:till_deposit).permit(
      :daily_reconciliation_id, :payment_method_id, :amount, :deposited_at, :reference, :notes,
      :idempotency_key
    )
  end

  # Bank transactions with no deposit yet, from statements whose date range
  # covers this deposit's business day — the reverse of
  # Finance::BankStatementTransactionsController#unmatched_deposits_for_manual_matching.
  def unmatched_transactions_for_manual_matching
    business_date = @deposit.daily_reconciliation.business_date

    statement_ids = BankStatement
                       .where(business: current_user.business)
                       .active
                       .where(status: "completed")
                       .where("statement_from <= ? AND statement_to >= ?", business_date, business_date)
                       .pluck(:id)

    BankStatementTransaction
      .where(bank_statement_id: statement_ids)
      .where.missing(:deposit_matches)
      .where.not(status: "ignored")
      .includes(:bank_statement)
      .order(transaction_date: :desc)
  end
end
