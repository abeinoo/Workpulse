class OpeningFloatsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_branch_and_dr

  def new
    authorize TillHandover, :leave_opening_float?

    unless @dr
      return redirect_to finance_daily_reconciliations_path,
                         alert: t("opening_floats.errors.no_closed_session")
    end

    @payment_methods = float_payment_methods
  end

  def create
    authorize TillHandover, :leave_opening_float?

    unless @dr
      return redirect_to finance_daily_reconciliations_path,
                         alert: t("opening_floats.errors.no_closed_session")
    end

    result = Finance::OpeningFloatLeaver.new(
      actor:                   current_user,
      daily_reconciliation_id: @dr.id,
      amounts:                 float_amounts_params
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@dr),
                  notice: t("opening_floats.created")
    else
      @payment_methods = float_payment_methods
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_branch_and_dr
    @branch = current_user.effective_branch_on(Date.current)
    @dr     = find_leavable_dr
  end

  def find_leavable_dr
    return nil unless @branch

    DailyReconciliation
      .where(state: %w[closed deposited], business_id: current_user.business_id, branch: @branch)
      .where.not(
        id: DailyReconciliation
              .joins(:till_handovers)
              .where(till_handovers: { opening_float_declaration: true })
              .select(:id)
      )
      .order(closed_at: :desc)
      .includes(:branch, :business)
      .first
  end

  def float_payment_methods
    business_payment_methods
  end

  def float_amounts_params
    return {} unless params[:opening_float].present?

    params.require(:opening_float)
          .permit(amounts: {})
          .dig(:amounts) || {}
  end
end
