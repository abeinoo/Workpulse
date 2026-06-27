class TillHandoversController < ApplicationController
  before_action :authenticate_user!
  before_action :set_handover, only: %i[show accept]

  # GET /my_shift
  # Redirects cashiers to the active reconciliation page.
  def my_shift
    authorize TillHandover, :my_shift?

    branch = current_user.shift_assignments.current.first&.branch
    unless branch
      @state = :no_branch
      return
    end

    open_recon = DailyReconciliation.open_for(branch)
    if open_recon
      session        = open_recon.till_session
      is_holder      = session&.current_holder_id == current_user.id
      pending_for_me = open_recon.till_handovers.pending.exists?(to_user_id: current_user.id)

      return redirect_to finance_daily_reconciliation_path(open_recon) if is_holder || pending_for_me
    end

    deposit_recon = DailyReconciliation
                      .closed
                      .where(business_id: current_user.business_id)
                      .joins(:till_session)
                      .where(till_sessions: { depositor_id: current_user.id })
                      .order(closed_at: :desc)
                      .first

    return redirect_to finance_daily_reconciliation_path(deposit_recon) if deposit_recon

    @state  = :no_activity
    @branch = branch
  end

  # GET /till_handovers/new
  def new
    @branch = current_user.shift_assignments.current.first&.branch
    authorize TillHandover.new, :create?
    setup_handover_form
  end

  # POST /till_handovers
  def create
    authorize TillHandover, :create?

    @branch = current_user.shift_assignments.current.first&.branch
    return redirect_to finance_daily_reconciliations_path,
                       alert: t("till_handovers.errors.no_branch") if @branch.nil?

    reconciliation = DailyReconciliation.open_for(@branch)
    return redirect_to finance_daily_reconciliations_path,
                       alert: t("till_handovers.errors.no_open_session") unless reconciliation

    result = Finance::TillHandoverCreator.new(
      actor:                current_user,
      daily_reconciliation: reconciliation,
      params:               handover_params
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(result.handover.daily_reconciliation),
                  notice: t("till_handovers.created")
    else
      setup_handover_form
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  # GET /till_handovers/:id
  def show
    authorize @handover
    @amounts = @handover.amounts.eager_load(:payment_method).order("payment_methods.position")
  end

  # PATCH /till_handovers/:id/accept
  def accept
    authorize @handover

    result = Finance::TillHandoverAcceptor.new(
      @handover,
      actor:          current_user,
      accepted_notes: params[:accepted_notes]
    ).call

    dest = finance_daily_reconciliation_path(@handover.daily_reconciliation)

    if result.ok?
      redirect_to dest, notice: t("till_handovers.accepted")
    else
      redirect_to dest, alert: result.error
    end
  end

  private

  def set_handover
    @handover = TillHandover
                  .joins(:daily_reconciliation)
                  .where(daily_reconciliations: { business_id: current_user.business_id })
                  .includes(:daily_reconciliation, :from_user, :to_user)
                  .find(params[:id])
  end

  def setup_handover_form
    @open_reconciliation = DailyReconciliation.open_for(@branch)
    @payment_methods     = business_payment_methods
    @colleagues          = branch_colleagues

    holder              = @open_reconciliation&.till_session&.current_holder
    has_pending_outgoing = @open_reconciliation&.till_handovers
                                               &.pending
                                               &.exists?(from_user_id: current_user.id,
                                                         self_deposit: false)
    @can_close_session = holder.present? &&
                         holder == current_user &&
                         !has_pending_outgoing

    last_received = @open_reconciliation&.till_handovers
                                        &.accepted
                                        &.where(to_user_id: current_user.id)
                                        &.order(accepted_at: :desc)
                                        &.includes(amounts: :payment_method)
                                        &.first
    @minimum_amounts = {}
    last_received&.amounts&.operational&.each do |amount|
      @minimum_amounts[amount.payment_method_id.to_s] = {
        collected: amount.collected_amount.to_f,
        refund:    amount.refund_amount.to_f
      }
    end

    @depositor_candidates = current_user.business.users
                              .active
                              .includes(:permission_role)
                              .where.not(id: current_user.id)
                              .order(:first_name)
                              .select { |u| u.can?(:create_till_deposit) }
  end

  def branch_colleagues
    return [] unless @branch

    ids = ShiftAssignment.current
                         .where(branch: @branch)
                         .where.not(user_id: current_user.id)
                         .pluck(:user_id)

    current_user.business.users
                .active
                .includes(:permission_role)
                .where(id: ids)
                .order(:first_name)
                .select { |u| u.can?(:accept_till_handover) }
  end

  def handover_params
    params.require(:till_handover).permit(
      :to_user_id, :notes, :self_deposit, :depositor_type, :depositor_id,
      amounts: {},
      next_day_amounts: {}
    )
  end
end
