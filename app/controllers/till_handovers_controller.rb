class TillHandoversController < ApplicationController
  before_action :authenticate_user!
  before_action :set_handover, only: %i[show accept]

  # GET /my_shift
  # The receptionist's shift hub — shows current till status and pending actions.
  def my_shift
    @branch        = current_user.shift_assignments.current.first&.branch
    @business_date = BusinessDay.current(context: current_user.business)
    @current_handover = @branch &&
      TillHandover.current_holder_for(@branch, @business_date)
    @pending_incoming = @branch &&
      TillHandover
        .for_branch_date(@branch, @business_date)
        .pending
        .where(to_user_id: current_user.id)
        .first
    @payment_methods = current_user.business
                                   .payment_methods
                                   .active
                                   .ordered
  end

  # GET /till_handovers/new
  def new
    @branch        = current_user.shift_assignments.current.first&.branch
    @business_date = BusinessDay.current(context: current_user.business)
    @handover      = TillHandover.new
    @payment_methods = current_user.business.payment_methods.active.ordered
    authorize @handover
  end

  # POST /till_handovers
  def create
    authorize TillHandover
    @branch        = current_user.shift_assignments.current.first&.branch
    @business_date = BusinessDay.current(context: current_user.business)

    result = Finance::TillHandoverCreator.new(
      actor:         current_user,
      branch:        @branch,
      business_date: @business_date,
      params:        handover_params
    ).call

    if result.ok?
      redirect_to my_shift_path, notice: t("till_handovers.created")
    else
      @handover        = TillHandover.new
      @payment_methods = current_user.business.payment_methods.active.ordered
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  # GET /till_handovers/:id
  def show
    authorize @handover
  end

  # PATCH /till_handovers/:id/accept
  def accept
    authorize @handover

    result = Finance::TillHandoverAcceptor.new(@handover, actor: current_user).call

    if result.ok?
      redirect_to my_shift_path, notice: t("till_handovers.accepted")
    else
      redirect_to my_shift_path, alert: result.error
    end
  end

  private

  def set_handover
    @handover = TillHandover
                  .where(business: current_user.business)
                  .find(params[:id])
  end

  def handover_params
    params.require(:till_handover).permit(
      :handover_type, :to_user_id, :notes,
      lines: {}
    )
  end
end
