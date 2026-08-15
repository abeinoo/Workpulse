class TillHandoversController < ApplicationController
  before_action :authenticate_user!
  before_action :set_handover, only: %i[show accept cancel reject reverse_form reverse new_adjustment create_adjustment]

  # GET /my_shift
  # Redirects cashiers to the active reconciliation page.
  def my_shift
    authorize TillHandover, :my_shift?

    branch = current_user.shift_assignments.current.first&.branch
    unless branch
      @state = :no_branch
      return
    end

    # A waiting_for_opening DR takes precedence — cashier must receive the float
    # before any other till operations are available.
    waiting_recon = DailyReconciliation.waiting_for(branch)
    return redirect_to finance_daily_reconciliation_path(waiting_recon) if waiting_recon

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
    authorize TillHandover.new, :create?

    @branch = resolve_branch
    return redirect_to finance_daily_reconciliations_path,
                       alert: t("till_handovers.errors.no_branch") if @branch.nil?

    setup_handover_form
  end

  # POST /till_handovers
  def create
    authorize TillHandover, :create?

    @branch = resolve_branch
    return redirect_to finance_daily_reconciliations_path,
                       alert: t("till_handovers.errors.no_branch") if @branch.nil?

    reconciliation = DailyReconciliation.open_for(@branch)
    return redirect_to finance_daily_reconciliations_path,
                       alert: t("till_handovers.errors.no_open_session") unless reconciliation

    result = Finance::TillHandoverCreator.new(
      actor:                   current_user,
      daily_reconciliation_id: reconciliation.id,
      params:                  handover_params
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

  # PATCH /till_handovers/:id/cancel
  def cancel
    authorize @handover

    result = Finance::TillHandoverCanceller.new(@handover.id, actor: current_user).call

    dest = finance_daily_reconciliation_path(@handover.daily_reconciliation)

    if result.ok?
      redirect_to dest, notice: t("till_handovers.cancelled")
    else
      redirect_to dest, alert: result.error
    end
  end

  # PATCH /till_handovers/:id/reject
  def reject
    authorize @handover

    result = Finance::TillHandoverRejecter.new(@handover.id, actor: current_user, reason: params[:reason]).call

    dest = finance_daily_reconciliation_path(@handover.daily_reconciliation)

    if result.ok?
      redirect_to dest, notice: t("till_handovers.rejected")
    else
      redirect_to dest, alert: result.error
    end
  end

  # GET /till_handovers/:id/reverse_form
  def reverse_form
    authorize @handover, :reverse?
    @reason_codes = Finance::TillHandoverReverser::REVERSAL_REASON_CODES
    @amounts = @handover.amounts.eager_load(:payment_method).order("payment_methods.position")
  end

  # PATCH /till_handovers/:id/reverse
  def reverse
    authorize @handover, :reverse?

    result = Finance::TillHandoverReverser.new(
      handover_id:  @handover.id,
      actor:        current_user,
      reason_code:  params[:reason_code],
      reason_notes: params[:reason_notes]
    ).call

    dest = finance_daily_reconciliation_path(@handover.daily_reconciliation)

    if result.ok?
      redirect_to dest, notice: t("till_handovers.reversed")
    else
      @reason_codes = Finance::TillHandoverReverser::REVERSAL_REASON_CODES
      @amounts = @handover.amounts.eager_load(:payment_method).order("payment_methods.position")
      flash.now[:alert] = result.error
      render :reverse_form, status: :unprocessable_entity
    end
  end

  # GET /till_handovers/:id/new_adjustment
  def new_adjustment
    authorize @handover, :adjust?
    @reason_codes  = Finance::TillHandoverAdjuster::REASON_CODES
    @amounts       = @handover.amounts.eager_load(:payment_method).order("payment_methods.position")
    @payment_methods = business_payment_methods
  end

  # POST /till_handovers/:id/create_adjustment
  def create_adjustment
    authorize @handover, :adjust?

    result = Finance::TillHandoverAdjuster.new(
      handover:    @handover,
      actor:       current_user,
      reason_code: params[:reason_code],
      notes:       params[:notes],
      after_data:  after_data_params
    ).call

    dest = finance_daily_reconciliation_path(@handover.daily_reconciliation)

    if result.ok?
      redirect_to dest, notice: t("till_handovers.adjustment_recorded")
    else
      @reason_codes    = Finance::TillHandoverAdjuster::REASON_CODES
      @amounts         = @handover.amounts.eager_load(:payment_method).order("payment_methods.position")
      @payment_methods = business_payment_methods
      flash.now[:alert] = result.error
      render :new_adjustment, status: :unprocessable_entity
    end
  end

  # PATCH /till_handovers/:id/accept
  def accept
    authorize @handover

    result = Finance::TillHandoverAcceptor.new(
      @handover.id,
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
    # Allow closing when nobody explicitly holds the till (nil) OR when the
    # actor is the current holder.  Only block if someone else holds it.
    # This mirrors validate_actor_is_holder! in TillHandoverCreator exactly.
    nobody_else_holds = holder.nil? || holder == current_user
    @can_close_session = nobody_else_holds && !has_pending_outgoing

    last_received = @open_reconciliation&.till_handovers
                                        &.accepted
                                        &.where(to_user_id: current_user.id)
                                        &.order(accepted_at: :desc)
                                        &.includes(:financial_adjustments, amounts: :payment_method)
                                        &.first
    @minimum_amounts = {}
    last_received&.effective_operational_amounts&.each do |amount|
      @minimum_amounts[amount[:payment_method_id].to_s] = {
        collected: amount[:collected_amount].to_f,
        refund:    amount[:refund_amount].to_f
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

    scope = current_user.business.users
                        .active
                        .includes(:permission_role)
                        .where(id: ids)
                        .order(:first_name)

    # Users with organization-wide DR authority (Super Admin, or any role
    # explicitly scoped business-wide on view_daily_reconciliation — the same
    # umbrella permission Finance::DailyReconciliationsController already
    # treats as "reaches every branch") may hand the cashier over to any
    # active employee in the branch — the accept_till_handover permission
    # filter only applies to ordinary branch-scoped users.
    return scope.to_a if business_wide_dr_access?

    scope.select { |u| u.can?(:accept_till_handover) }
  end

  def business_wide_dr_access?
    current_user.owner? || current_user.scope_for(:view_daily_reconciliation) == "business"
  end

  # Ordinary cashiers act on the branch they're physically shift-assigned to —
  # that path is unchanged. Administrative actors (Super Admin, Area Manager,
  # or anyone else explicitly granted a business/area-wide
  # view_daily_reconciliation scope) have no shift assignment of their own but
  # are still permitted to close_till_session — for them the target branch
  # comes from the Daily Reconciliation they're acting on (passed as
  # daily_reconciliation_id from the DR show page), not from a fabricated
  # "current branch". Permission (close_till_session, checked by the policy)
  # is what authorizes the action; this only resolves *which* branch it acts on.
  def resolve_branch
    own_branch = current_user.shift_assignments.current.first&.branch
    return own_branch if own_branch

    return nil unless params[:daily_reconciliation_id].present?

    target = DailyReconciliation
               .where(business_id: current_user.business_id)
               .includes(:branch)
               .find_by(id: params[:daily_reconciliation_id])
    return nil unless target && branch_authorized_for_dr_action?(target.branch)

    target.branch
  end

  def branch_authorized_for_dr_action?(branch)
    return false unless branch
    return true if business_wide_dr_access?

    BranchScope.new(current_user, include_shift_assignments: true)
               .for_scope(current_user.scope_for(:view_daily_reconciliation))
               .include?(branch.id)
  end

  def handover_params
    params.require(:till_handover).permit(
      :to_user_id, :notes, :self_deposit, :depositor_type, :depositor_id,
      amounts: {}
    )
  end

  # Collects the after_amounts hash from the adjustment form.
  # Each key is a payment_method_id; value is a hash with collected/refund amounts.
  def after_data_params
    return [] unless params[:after_data].present?

    params.require(:after_data).to_unsafe_h.map do |pm_id, values|
      {
        payment_method_id:   pm_id.to_i,
        collected_amount:    values[:collected_amount].to_s,
        refund_amount:       values[:refund_amount].to_s
      }
    end.reject { |e| e[:collected_amount].blank? && e[:refund_amount].blank? }
  end
end
