class Finance::DailyReconciliationsController < Finance::BaseController
  before_action :set_reconciliation, only: %i[show verify assign_depositor receive_opening_float
                                               edit_session_totals update_session_totals]

  # GET /finance/daily_reconciliations
  def index
    authorize DailyReconciliation

    @current_business_day = BusinessDay.current(context: current_user.business)

    query = DailyReconciliation
              .where(business_id: current_user.business_id)
              .includes(:branch, :remaining_deposit_balances,
                        opening_float_source_handover: :from_user,
                        till_session: %i[current_holder depositor])
              .order(opened_at: :desc)
              .limit(200)

    unless current_user.owner?
      scope_name = current_user.scope_for(:view_daily_reconciliation)
      if scope_name
        branch_ids = BranchScope.new(current_user).for_scope(scope_name)
        if branch_ids.empty? && scope_name != "business"
          branch_ids = current_user.shift_assignments.current.pluck(:branch_id).uniq
        end
        query = query.where(branch_id: branch_ids) unless branch_ids.empty?
      end
    end

    # ── Optional filters ─────────────────────────────────────────────────────
    @filter_status = params[:status].presence
    @filter_branch = params[:branch_id].presence
    @filter_date   = params[:business_date].presence

    query = apply_dr_filters(query)

    @reconciliations    = query
    @accessible_branches = accessible_branches_for_dr
  end

  # POST /finance/daily_reconciliations/bulk_settle
  def bulk_settle
    authorize DailyReconciliation, :bulk_settle?

    ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
    if ids.empty?
      return redirect_to finance_daily_reconciliations_path,
                         alert: t("finance.daily_reconciliations.errors.bulk_none_selected")
    end

    pm = business_payment_methods.find_by(id: params[:payment_method_id])
    unless pm
      return redirect_to finance_daily_reconciliations_path,
                         alert: t("finance.daily_reconciliations.errors.bulk_settle_no_pm")
    end

    reconciliations = policy_scope(DailyReconciliation)
                        .where(id: ids)
                        .includes(:business, :branch,
                                  remaining_deposit_balances: :balance_transactions)

    successes = 0
    failures  = 0

    reconciliations.each do |dr|
      dr.remaining_deposit_balances.open.each do |rdb|
        result = Finance::RemainingDepositBalanceSettler.new(
          rdb,
          actor:             current_user,
          amount:            rdb.remaining_amount,
          notes:             params[:notes].presence || t("finance.daily_reconciliations.bulk_settle_default_notes"),
          payment_method_id: pm.id,
          reference_number:  params[:reference_number].presence
        ).call
        result.ok? ? successes += 1 : failures += 1
      end
    end

    if failures.zero? && successes > 0
      redirect_to finance_daily_reconciliations_path(filter_params),
                  notice: t("finance.daily_reconciliations.bulk_settle_done", count: successes)
    elsif successes > 0
      redirect_to finance_daily_reconciliations_path(filter_params),
                  notice: t("finance.daily_reconciliations.bulk_settle_partial",
                             success: successes, failure: failures)
    else
      redirect_to finance_daily_reconciliations_path(filter_params),
                  alert: t("finance.daily_reconciliations.errors.bulk_settle_failed")
    end
  end

  # POST /finance/daily_reconciliations/bulk_receive_opening_float
  def bulk_receive_opening_float
    authorize DailyReconciliation, :bulk_receive_opening_float?

    ids = Array(params[:ids]).map(&:to_i).uniq.reject(&:zero?)
    if ids.empty?
      return redirect_to finance_daily_reconciliations_path,
                         alert: t("finance.daily_reconciliations.errors.bulk_none_selected")
    end

    reconciliations = policy_scope(DailyReconciliation)
                        .where(id: ids)
                        .includes(:business, :branch, :till_session,
                                  opening_float_source_handover: { amounts: :payment_method, from_user: [] })

    successes = 0
    failures  = 0

    reconciliations.each do |dr|
      next unless dr.opening_float_receivable?

      result = Finance::OpeningFloatReceiver.new(
        daily_reconciliation: dr,
        actor: current_user
      ).call
      result.ok? ? successes += 1 : failures += 1
    end

    if failures.zero? && successes > 0
      redirect_to finance_daily_reconciliations_path,
                  notice: t("finance.daily_reconciliations.bulk_opening_float_received", count: successes)
    elsif successes > 0
      redirect_to finance_daily_reconciliations_path,
                  notice: t("finance.daily_reconciliations.bulk_opening_float_partial",
                             success: successes, failure: failures)
    else
      redirect_to finance_daily_reconciliations_path,
                  alert: t("finance.daily_reconciliations.errors.bulk_receive_failed")
    end
  end

  # GET /finance/daily_reconciliations/new
  def new
    authorize DailyReconciliation, :create?
    @branches = accessible_branches_for_dr
    redirect_to finance_daily_reconciliations_path,
                alert: t("finance.daily_reconciliations.errors.no_branch") if @branches.empty?
  end

  # GET /finance/daily_reconciliations/:id
  def show
    authorize @reconciliation
    @session  = @reconciliation.till_session
    @handovers = @reconciliation.till_handovers
                                .includes(:from_user, :to_user, :cancelled_by,
                                          :reversed_by,
                                          reversal_of_handover: :from_user,
                                          amounts:              :payment_method,
                                          seeded_daily_reconciliation: [])
                                .order(:created_at)
    @waiting_for_opening_float      = @reconciliation.blocked_by_opening_float?
    @opening_float_receivable       = @reconciliation.opening_float_receivable?
    @opening_float_source_handover = if @waiting_for_opening_float
                                       @reconciliation.opening_float_source_handover
                                                      &.then { |h| h.amounts.next_day.includes(:payment_method).order("payment_methods.position").to_a }
    end
    @deposits  = @reconciliation.active_deposits
                               .includes(:payment_method, :deposited_by)
                               .order(:deposited_at)

    # Full deposit history (including voided) is needed only by the timeline.
    @all_deposits = @reconciliation.till_deposits
                                   .includes(:payment_method, :deposited_by, :voided_by)
                                   .order(:deposited_at)

    @amounts_by_method = @reconciliation.session_amounts
                                        .includes(:payment_method)
                                        .order("payment_methods.position")
    @total_deposited   = @reconciliation.total_deposited

    @i_am_depositor = @session&.depositor_id == current_user.id
    @pending_handover_for_me   = @reconciliation.till_handovers.pending.find_by(to_user_id: current_user.id)
    @pending_outgoing_handover = @reconciliation.till_handovers.pending
                                               .find_by(from_user_id: current_user.id, self_deposit: false)

    @all_deposit_transfers     = @reconciliation.deposit_responsibility_transfers
                                                .includes(:from_user, :to_user, :cancelled_by)
                                                .order(:created_at)
    @pending_deposit_transfer          = @all_deposit_transfers.find(&:pending?)
    @pending_deposit_transfer_for_me   = @pending_deposit_transfer if @pending_deposit_transfer&.to_user_id   == current_user.id
    @pending_deposit_transfer_from_me  = @pending_deposit_transfer if @pending_deposit_transfer&.from_user_id == current_user.id

    @all_remaining_balances = @reconciliation.remaining_deposit_balances
                                              .includes(:responsible_user, :created_by, :till_deposit,
                                                         balance_transactions: %i[performed_by
                                                                                  previous_responsible_user
                                                                                  new_responsible_user])
                                              .order(:created_at)
    @total_remaining_balance  = @reconciliation.total_remaining_balance
    @total_settled_later      = @reconciliation.total_settled_later
    @total_written_off        = @reconciliation.total_written_off

    @can_view_session_totals  = policy(@reconciliation).view_session_totals?
    @can_edit_session_totals  = policy(@reconciliation).edit_session_totals?
    @can_view_all_summary     = policy(@reconciliation).view_all_employee_reconciliation_summary?
    @can_view_own_summary     = policy(@reconciliation).view_own_employee_reconciliation_summary?

    summarizer = Finance::EmployeeReconciliationSummarizer.new(@reconciliation)
    @employee_summaries = if @can_view_all_summary
      summarizer.summaries
    elsif @can_view_own_summary
      summarizer.summaries(for_user: current_user)
    end

    @session_amount_edits = AuditLog
                              .where(auditable: @reconciliation, action: "edit_session_totals")
                              .includes(:actor)
                              .order(:created_at)
                              .to_a

    handover_ids = @handovers.map(&:id)
    @all_adjustments = handover_ids.any? ?
      FinancialAdjustment
        .where(adjustable_type: "TillHandover", adjustable_id: handover_ids)
        .includes(:actor, :approved_by)
        .order(:created_at) :
      []
    # Grouped for O(1) lookup per handover in the view (avoids N+1 on .select).
    @adjustments_by_handover_id = @all_adjustments.group_by(&:adjustable_id)

    @timeline_events = build_timeline_events
  end

  # POST /finance/daily_reconciliations
  def create
    authorize DailyReconciliation, :create?

    branch = resolve_branch
    return unless branch

    today = BusinessDay.current(context: branch.business)

    open_recon = DailyReconciliation.open_for(branch)
    if open_recon
      return redirect_to finance_daily_reconciliation_path(open_recon),
                         notice: t("finance.daily_reconciliations.errors.already_exists")
    end

    waiting_recon = DailyReconciliation.waiting_for(branch)
    if waiting_recon
      return redirect_to finance_daily_reconciliation_path(waiting_recon),
                         notice: t("finance.daily_reconciliations.errors.already_waiting")
    end

    closed_today = DailyReconciliation.where(branch: branch, business_date: today).first
    if closed_today
      return redirect_to finance_daily_reconciliation_path(closed_today),
                         notice: t("finance.daily_reconciliations.errors.already_exists")
    end

    recon = DailyReconciliation.create_for!(branch: branch, created_by: current_user)
    redirect_to finance_daily_reconciliation_path(recon),
                notice: t("finance.daily_reconciliations.created")
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    existing = DailyReconciliation.open_for(branch) ||
               DailyReconciliation.waiting_for(branch) ||
               DailyReconciliation.where(branch: branch, business_date: today).first
    if existing
      redirect_to finance_daily_reconciliation_path(existing),
                  notice: t("finance.daily_reconciliations.errors.already_exists")
    else
      redirect_to finance_daily_reconciliations_path,
                  alert: t("finance.daily_reconciliations.errors.create_failed")
    end
  end

  # PATCH /finance/daily_reconciliations/:id/verify
  def verify
    authorize @reconciliation, :verify?

    result = Finance::DailyReconciliationVerifier.new(
      @reconciliation,
      actor: current_user,
      notes: params[:notes]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.verified")
    else
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: result.error
    end
  end

  # POST /finance/daily_reconciliations/:id/receive_opening_float
  def receive_opening_float
    authorize @reconciliation, :receive_opening_float?

    result = Finance::OpeningFloatReceiver.new(
      daily_reconciliation: @reconciliation,
      actor:                current_user
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.opening_float_received")
    else
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: result.error
    end
  end

  # GET /finance/daily_reconciliations/:id/edit_session_totals
  def edit_session_totals
    authorize @reconciliation, :edit_session_totals?
    @amounts_by_method = @reconciliation.session_amounts
                                        .includes(:payment_method)
                                        .order("payment_methods.position")
    @edit_history = AuditLog
                      .where(auditable: @reconciliation, action: "edit_session_totals")
                      .includes(:actor)
                      .order(:created_at)
  end

  # PATCH /finance/daily_reconciliations/:id/update_session_totals
  def update_session_totals
    authorize @reconciliation, :edit_session_totals?

    result = Finance::SessionAmountsEditor.new(
      @reconciliation,
      actor:   current_user,
      amounts: (params[:amounts]&.to_unsafe_h || {}).transform_values { |v|
                 { collected_amount: v[:collected_amount], refund_amount: v[:refund_amount] }
               },
      notes:   params[:notes]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.session_totals_updated")
    else
      @amounts_by_method = @reconciliation.session_amounts
                                          .includes(:payment_method)
                                          .order("payment_methods.position")
      @edit_history = AuditLog
                        .where(auditable: @reconciliation, action: "edit_session_totals")
                        .includes(:actor)
                        .order(:created_at)
      flash.now[:alert] = result.error
      render :edit_session_totals, status: :unprocessable_entity
    end
  end

  # PATCH /finance/daily_reconciliations/:id/assign_depositor
  def assign_depositor
    authorize @reconciliation, :assign_depositor?

    if @reconciliation.deposit_responsibility_transfers.pending.exists?
      return redirect_to finance_daily_reconciliation_path(@reconciliation),
                         alert: t("finance.daily_reconciliations.errors.pending_transfer_exists")
    end

    depositor = current_user.business.users.active.find(params[:depositor_id])
    @reconciliation.till_session.update!(depositor: depositor)
    @reconciliation.log_audit(actor: current_user, auditable: @reconciliation,
                               action: "assign_depositor",
                               metadata: { depositor_id: depositor.id,
                                           depositor_name: depositor.full_name })
    redirect_to finance_daily_reconciliation_path(@reconciliation),
                notice: t("finance.daily_reconciliations.depositor_assigned")
  rescue ActiveRecord::RecordNotFound
    redirect_to finance_daily_reconciliation_path(@reconciliation),
                alert: t("finance.daily_reconciliations.errors.invalid_depositor")
  end

  private

  # Builds a flat, chronologically sorted array of timeline event hashes.
  # Each hash: { type: Symbol, time: Time, actor: User|nil, data: AR record }
  #
  # To add a new event type: push a hash here, then add a `when :new_type`
  # block in the view's case statement and add it to the appropriate stage in
  # STAGE_DEFS (see show.html.erb).
  def build_timeline_events
    events = []

    # The handover that received today's opening float (first transfer on this DR
    # when opening_float_source_handover is present).  Rendered differently from
    # a regular handover so it carries its own event type.
    opening_receipt_handover = if @reconciliation.opening_float_source_handover
                                 @handovers.first
    end

    @handovers.each do |h|
      if h.self_deposit?
        events << { type: :day_closed, time: h.created_at, actor: h.from_user, data: h }
        # If this self-deposit seeded the next day's DR, record the prepared event.
        # Pass the seeded DR (not the handover) so the view can display its business_date.
        if h.seeded_daily_reconciliation.present?
          events << { type: :opening_float_prepared, time: h.created_at, actor: h.from_user,
                      data: h.seeded_daily_reconciliation }
        end
      elsif h == opening_receipt_handover
        events << { type: :opening_float_received, time: h.accepted_at, actor: h.to_user, data: h } if h.accepted?
      elsif h.reversal?
        # A compensating reversal handover — auto-accepted by the service.
        events << { type: :handover_reversal_applied, time: h.accepted_at, actor: h.from_user, data: h }
      else
        events << { type: :handover_created,   time: h.created_at,   actor: h.from_user,    data: h }
        events << { type: :handover_accepted,  time: h.accepted_at,  actor: h.to_user,      data: h } if h.accepted? && !h.reversed?
        events << { type: :handover_cancelled, time: h.cancelled_at, actor: h.cancelled_by, data: h } if h.cancelled?
        events << { type: :handover_reversed,  time: h.reversed_at,  actor: h.reversed_by,  data: h } if h.reversed?
      end
    end

    (@all_adjustments || []).each do |adj|
      events << { type: :handover_adjusted, time: adj.created_at, actor: adj.actor, data: adj }
    end

    (@all_deposit_transfers || []).each do |drt|
      events << { type: :deposit_assigned,  time: drt.created_at,   actor: drt.from_user,    data: drt }
      events << { type: :deposit_accepted,  time: drt.accepted_at,  actor: drt.to_user,      data: drt } if drt.accepted?
      events << { type: :deposit_cancelled, time: drt.cancelled_at, actor: drt.cancelled_by, data: drt } if drt.cancelled?
    end

    # Use @all_deposits (includes voided) so voids appear in the audit trail.
    (@all_deposits || @deposits).each do |d|
      events << { type: :deposit_recorded, time: d.deposited_at, actor: d.deposited_by, data: d }
      events << { type: :deposit_voided,   time: d.voided_at,    actor: d.voided_by,    data: d } if d.voided?
    end

    # Map ledger transaction types to timeline event symbols.
    txn_type_map = {
      "created"     => :remaining_created,
      "settlement"  => :remaining_settled,
      "reassignment"=> :remaining_reassigned,
      "write_off"   => :remaining_written_off,
      "adjustment"  => :remaining_adjusted
    }

    (@all_remaining_balances || []).each do |rdb|
      rdb.balance_transactions.each do |txn|
        type = txn_type_map[txn.transaction_type]
        next unless type
        events << { type: type, time: txn.created_at, actor: txn.performed_by, data: txn, balance: rdb }
      end
    end

    (@session_amount_edits || []).each do |log|
      events << { type: :session_totals_edited, time: log.created_at, actor: log.actor, data: log }
    end

    if @reconciliation.verified?
      events << { type: :day_verified, time: @reconciliation.verified_at,
                  actor: @reconciliation.verified_by, data: @reconciliation }
    end

    events.sort_by! { |e| e[:time] }
  end

  def set_reconciliation
    @reconciliation = policy_scope(DailyReconciliation)
                        .includes(:branch, :business, :verified_by,
                                  session_amounts:               :payment_method,
                                  till_session:                  %i[depositor closed_by current_holder],
                                  opening_float_source_handover: { amounts: :payment_method, from_user: [] })
                        .find(params[:id])
  end

  def resolve_branch
    if params[:branch_id].present?
      accessible = accessible_branches_for_dr
      branch = accessible.find { |b| b.id == params[:branch_id].to_i }
      unless branch
        redirect_to new_finance_daily_reconciliation_path,
                    alert: t("finance.daily_reconciliations.errors.invalid_branch")
        return nil
      end
      branch
    else
      branches = accessible_branches_for_dr
      case branches.size
      when 0
        redirect_to finance_daily_reconciliations_path,
                    alert: t("finance.daily_reconciliations.errors.no_branch")
        nil
      when 1
        branches.first
      else
        redirect_to new_finance_daily_reconciliation_path
        nil
      end
    end
  end

  def accessible_branches_for_dr
    return current_user.business.branches.active.order(:name).to_a if current_user.owner?

    scope_name = current_user.scope_for(:view_daily_reconciliation)

    # nil scope is consistent with the index query: no explicit restriction → all branches.
    # An explicit scope (branch / area / business) narrows access via BranchScope.
    return current_user.business.branches.active.order(:name).to_a unless scope_name

    ids = BranchScope.new(current_user).for_scope(scope_name)
    if ids.empty? && scope_name != "business"
      shift_branch = current_user.shift_assignments.current.first&.branch
      return shift_branch ? [ shift_branch ] : []
    end
    current_user.business.branches.active.where(id: ids).order(:name).to_a
  end

  def apply_dr_filters(query)
    case @filter_status
    when "waiting_opening"
      query = query.waiting_for_opening
    when "outstanding"
      query = query.joins(:remaining_deposit_balances)
                   .where(remaining_deposit_balances: { status: "open" })
                   .distinct
    when "waiting_verification"
      query = query.where(state: "closed").or(query.where(state: "deposited"))
                   .where(verified_at: nil)
    when "verified"
      query = query.where.not(verified_at: nil)
    end

    if @filter_branch.present?
      query = query.where(branch_id: @filter_branch.to_i)
    end

    if @filter_date.present?
      date = Date.parse(@filter_date) rescue nil
      query = query.where(business_date: date) if date
    end

    query
  end

  def filter_params
    params.permit(:status, :branch_id, :business_date)
  end
end
