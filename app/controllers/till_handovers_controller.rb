class TillHandoversController < ApplicationController
  before_action :authenticate_user!
  before_action :set_handover, only: %i[show accept cancel reject reverse_form reverse new_adjustment create_adjustment]

  # GET /my_shift
  # Redirects cashiers to the active reconciliation page.
  def my_shift
    authorize TillHandover, :my_shift?

    # A deposit responsibility transfer waiting for this employee's answer —
    # personal, so it doesn't depend on today's branch assignment.
    transfer_recon = DailyReconciliation
                       .where(business_id: current_user.business_id)
                       .joins(:deposit_responsibility_transfers)
                       .merge(DepositResponsibilityTransfer.pending.where(to_user_id: current_user.id))
                       .order(closed_at: :desc)
                       .first

    return redirect_to finance_daily_reconciliation_path(transfer_recon) if transfer_recon

    branch = current_user.effective_branch_on(Date.current)
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

    reconciliation = target_reconciliation
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
    @open_reconciliation = target_reconciliation
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
                              .select(&:eligible_depositor?)
  end

  # Historical-context colleague list: when acting on a specific target
  # reconciliation, candidates are resolved from ITS OWN business_date (via
  # ShiftAssignment#active_on), never Date.current/today. A historical DR at
  # a branch the actor was only temporarily assigned to (now expired) must
  # still list the employees who were actually shift-assigned there ON THAT
  # DATE — not the actor's own today's colleagues, and not "everyone who has
  # ever worked there" either. Falls back to today when there is no specific
  # target DR to anchor on (e.g. no open session yet at all) — the same
  # "who's here right now" semantics the old ShiftAssignment.current scope
  # provided.
  def branch_colleagues
    return [] unless @branch

    colleague_date = target_reconciliation&.business_date || Date.current

    ids = ShiftAssignment.active_on(colleague_date)
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

  # ── Resolving the target DailyReconciliation/branch for this action ──────
  #
  # An explicit daily_reconciliation_id (the DR show page always passes one
  # when opening this modal) takes priority over the actor's own today's
  # branch — it may be a HISTORICAL reconciliation whose branch differs from
  # current_user.effective_branch_on(Date.current) (e.g. finishing an
  # existing session at a branch covered only by a now-expired temporary
  # ShiftAssignment). Falling back to "my current branch" there would
  # silently substitute a completely different DR — today's own, at the
  # actor's own branch — corrupting both the colleague list
  # (#branch_colleagues) and the current-holder check (#setup_handover_form).
  #
  # If the given id doesn't resolve to a real, authorized DailyReconciliation
  # (missing, wrong business, or genuinely out of the actor's access), this
  # falls back to the actor's own current-day branch instead of failing
  # outright — the same graceful behavior as when no id is given at all (a
  # stray/garbage param must never be worse than not passing one).
  #
  # Authorization combines BOTH halves of how the DR show page itself
  # authorizes a single record: policy_scope (branch/area/business scope, or
  # — for a non-manager holding the permission but no management scope —
  # the ShiftAssignment#active_on(business_date) correlation) AND
  # DailyReconciliationPolicy#show? (which additionally covers a plain
  # cashier with NO view_daily_reconciliation permission at all, via being
  # the historical holder/depositor/pending-recipient on the DR's own
  # TillSession/TillHandover records). Neither check alone is enough: show?
  # alone ignores branch/area scope entirely (it assumes the record was
  # already scope-filtered upstream, as the DR show page does via
  # policy_scope(...).find(id)); policy_scope alone would return every DR
  # unrestricted for a permission-less user (Scope#resolve's own "no scope
  # configured" bailout), bypassing the real custody check.
  def find_authorized_target_dr
    return @find_authorized_target_dr if defined?(@find_authorized_target_dr)

    target = DailyReconciliation
               .where(business_id: current_user.business_id)
               .includes(:branch, :till_session)
               .find_by(id: params[:daily_reconciliation_id])

    @find_authorized_target_dr =
      if target && policy_scope(DailyReconciliation).exists?(id: target.id) &&
         DailyReconciliationPolicy.new(current_user, target).show?
        target
      end
  end

  def resolve_branch
    if params[:daily_reconciliation_id].present?
      explicit = find_authorized_target_dr
      return explicit.branch if explicit
    end

    current_user.effective_branch_on(Date.current)
  end

  # The SPECIFIC DailyReconciliation this handover action targets — same
  # explicit-id-first priority as #resolve_branch (see its comment), reused
  # here so the colleague list and the current-holder check both operate on
  # the exact DR the actor came here to act on, not merely "whatever's open
  # at @branch" (which could theoretically diverge if more than one DR was
  # ever open at once). Requires the target to still be `open?` — mirrors
  # the previous DailyReconciliation.open_for(@branch) precondition.
  def target_reconciliation
    return @target_reconciliation if defined?(@target_reconciliation)

    explicit = params[:daily_reconciliation_id].present? ? find_authorized_target_dr : nil

    @target_reconciliation =
      if explicit
        explicit.open? ? explicit : nil
      else
        DailyReconciliation.open_for(@branch)
      end
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
