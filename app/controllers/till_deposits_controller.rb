class TillDepositsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_deposit, only: %i[void]

  # GET /till_deposits/new?daily_reconciliation_id=:id
  def new
    @reconciliation  = find_depositor_reconciliation(params[:daily_reconciliation_id])
    @deposit         = TillDeposit.new(daily_reconciliation: @reconciliation)
    @payment_methods = business_payment_methods.select(&:cash_like?)
    @expected_amounts_by_pm = expected_amounts_by_pm(@reconciliation, @payment_methods)
    @idempotency_key = SecureRandom.uuid
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
      # Preserve the same key on re-render so a retry of this exact failed
      # submission stays idempotent rather than minting a fresh one.
      @idempotency_key = deposit_params[:idempotency_key].presence || SecureRandom.uuid
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  # PATCH /till_deposits/:id/void
  def void
    authorize @deposit

    dest = finance_daily_reconciliation_path(@deposit.daily_reconciliation)

    if @deposit.update(voided_at: Time.current, voided_by: current_user,
                       void_reason: params[:void_reason])
      @deposit.log_audit(actor: current_user, auditable: @deposit, action: "void",
                         metadata: { void_reason: params[:void_reason],
                                     amount:       @deposit.amount.to_s })
      redirect_to dest, notice: t("till_deposits.voided")
    else
      redirect_to dest, alert: @deposit.errors.full_messages.to_sentence
    end
  end

  private

  def set_deposit
    @deposit = TillDeposit
                 .joins(:daily_reconciliation)
                 .where(daily_reconciliations: { business_id: current_user.business_id })
                 .find(params[:id])
  end

  def find_depositor_reconciliation(id)
    DailyReconciliation
      .where(business_id: current_user.business_id)
      .includes(session_amounts: :payment_method)
      .find(id)
  end

  # Returns a Hash { pm_id => expected_pending_amount } for use in the form.
  # Expected = session total for that PM minus what's already been deposited.
  def expected_amounts_by_pm(reconciliation, payment_methods)
    already_deposited = reconciliation.till_deposits.active
                                      .group(:payment_method_id)
                                      .sum(:amount)
    session_totals = reconciliation.session_amounts
                                   .each_with_object({}) do |sa, h|
                                     h[sa.payment_method_id] = sa.net_amount
                                   end
    payment_methods.each_with_object({}) do |pm, h|
      h[pm.id] = [(session_totals[pm.id] || 0) - (already_deposited[pm.id] || 0), 0].max
    end
  end

  def deposit_params
    params.require(:till_deposit).permit(
      :daily_reconciliation_id, :payment_method_id, :amount, :deposited_at, :reference, :notes,
      :override_review_reason, :idempotency_key
    )
  end
end
