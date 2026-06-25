class TillDepositsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_deposit, only: %i[void]

  # GET /till_deposits/new?till_handover_id=:id
  def new
    @till_handover   = find_depositor_handover(params[:till_handover_id])
    @deposit         = TillDeposit.new(till_handover: @till_handover)
    @payment_methods = current_user.business
                                   .payment_methods
                                   .active
                                   .ordered
                                   .select(&:cash_like?)
    authorize @deposit
  end

  # POST /till_deposits
  def create
    @till_handover = find_depositor_handover(deposit_params[:till_handover_id])
    @deposit       = TillDeposit.new(till_handover: @till_handover)
    authorize @deposit

    result = Finance::TillDepositRecorder.new(
      @till_handover,
      actor:  current_user,
      params: deposit_params
    ).call

    if result.ok?
      redirect_to my_shift_path, notice: t("till_deposits.created")
    else
      @payment_methods = current_user.business
                                     .payment_methods
                                     .active
                                     .ordered
                                     .select(&:cash_like?)
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  # PATCH /till_deposits/:id/void
  def void
    authorize @deposit

    if @deposit.update(voided_at: Time.current, voided_by: current_user,
                       void_reason: params[:void_reason])
      redirect_to my_shift_path, notice: t("till_deposits.voided")
    else
      redirect_to my_shift_path, alert: @deposit.errors.full_messages.to_sentence
    end
  end

  private

  def set_deposit
    @deposit = TillDeposit
                 .joins(:till_handover)
                 .where(till_handovers: { business_id: current_user.business_id })
                 .find(params[:id])
  end

  def find_depositor_handover(id)
    TillHandover
      .where(business: current_user.business)
      .find(id)
  end

  def deposit_params
    params.require(:till_deposit).permit(
      :till_handover_id, :payment_method_id, :amount, :deposited_at, :reference, :notes
    )
  end
end
