class Finance::DailyReconciliationsController < Finance::BaseController
  # Lightweight value object for displaying override amounts in the view.
  # Mirrors the TillHandoverAmount interface used by the waiting card partial.
  OpeningFloatDisplayAmount = Struct.new(:payment_method_name, :collected_amount, :refund_amount) do
    def net_amount = collected_amount - refund_amount
  end

  before_action :set_reconciliation, only: %i[show verify assign_depositor
                                               edit_opening_float update_opening_float_amounts receive_opening_float
                                               edit_session_totals update_session_totals
                                               correct_opening_float update_opening_float_correction]

  # GET /finance/daily_reconciliations
  def index
    authorize DailyReconciliation

    @current_business_day = BusinessDay.current(context: current_user.business)

    @show_verification = current_user.can?(:view_deposit_verification)

    query = DailyReconciliation
              .where(business_id: current_user.business_id)
              .includes(:branch, :remaining_deposit_balances,
                        opening_float_source_handover: :from_user,
                        till_session: %i[current_holder depositor])
              .order(opened_at: :desc)
              .limit(200)

    query = query.includes(till_deposits: :bank_statement_transaction) if @show_verification

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
    @filter_status       = params[:status].presence
    @filter_branch       = params[:branch_id].presence
    @filter_date         = params[:business_date].presence
    @filter_verification = @show_verification ? params[:verification_status].presence : nil

    query = apply_dr_filters(query)

    if @show_verification
      all_drs = query.to_a
      @verification_counts = Hash.new(0)
      all_drs.each { |dr| @verification_counts[deposit_verification_status_for(dr)] += 1 }
      @reconciliations = @filter_verification ?
        all_drs.select { |dr| deposit_verification_status_for(dr).to_s == @filter_verification } :
        all_drs
    else
      @reconciliations = query
    end

    @accessible_branches = accessible_branches_for_dr

    @latest_pos_import = current_user.business.pos_imports.imported.order(updated_at: :desc)
                                     .includes(:imported_by).first if current_user.can?(:manage_pos_import)
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
          rdb.id,
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
        daily_reconciliation_id: dr.id,
        actor:                   current_user
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
                                          :reversed_by, :superseded_by,
                                          reversal_of_handover: :from_user,
                                          corrects_handover:    :from_user,
                                          amounts:              :payment_method,
                                          seeded_daily_reconciliation: [])
                                .order(:created_at)
    @waiting_for_opening_float = @reconciliation.blocked_by_opening_float?
    @opening_float_receivable  = @reconciliation.opening_float_receivable?

    if @waiting_for_opening_float
      source_handover = @reconciliation.opening_float_source_handover
      source_amounts  = source_handover&.amounts
                                       &.next_day
                                       &.includes(:payment_method)
                                       &.order("payment_methods.position")
                                       &.to_a || []

      @opening_float_source_handover    = source_amounts
      @opening_float_amounts_overridden = @reconciliation.opening_float_override_amounts.present?

      if @opening_float_amounts_overridden
        override_list = @reconciliation.opening_float_override_amounts

        # Load payment methods for canonical position ordering.
        pm_ids   = override_list.map { |o| o["payment_method_id"].to_i }.uniq
        pm_by_id = PaymentMethod.where(id: pm_ids).index_by(&:id)

        # Show only entries that will actually be transferred (non-zero amounts),
        # ordered by the payment method's configured position.
        @opening_float_display_amounts = override_list
          .select { |o| o["collected_amount"].to_d.positive? || o["refund_amount"].to_d.positive? }
          .sort_by { |o| pm_by_id[o["payment_method_id"].to_i]&.position || 9999 }
          .map do |o|
            OpeningFloatDisplayAmount.new(
              o["payment_method_name"],
              o["collected_amount"].to_d,
              o["refund_amount"].to_d
            )
          end
      else
        @opening_float_display_amounts = source_amounts
      end
    end

    @can_edit_opening_float = @waiting_for_opening_float &&
                              @reconciliation.opening_float_source_handover_id.present? &&
                              policy(@reconciliation).update_opening_float_amounts?
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

    @opening_float_leavable = (@reconciliation.closed? || @reconciliation.deposited?) &&
                              @handovers.none?(&:opening_float_declaration?) &&
                              BusinessDay.current(context: @reconciliation.business) == @reconciliation.business_date

    @can_view_session_totals     = policy(@reconciliation).view_session_totals?
    @can_edit_session_totals     = policy(@reconciliation).edit_session_totals?
    @can_view_all_summary        = policy(@reconciliation).view_all_employee_reconciliation_summary?
    @can_view_own_summary        = policy(@reconciliation).view_own_employee_reconciliation_summary?

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

    @can_manage_pos_import = policy(@reconciliation).manage_pos_import?

    # Load POS transactions linked to this DR for the comparison sections.
    @pos_transactions = @reconciliation.pos_transactions
                                       .order(:transaction_date, :cashier_name, :payment_method_name)
                                       .to_a
    @pos_totals_by_method  = @pos_transactions
                               .group_by(&:payment_method_name)
                               .transform_values { |txns| txns.sum(&:amount) }
    @pos_totals_by_cashier = @pos_transactions
                               .group_by(&:cashier_name)
                               .transform_values { |txns|
                                 txns.group_by(&:payment_method_name)
                                     .transform_values { |t| t.sum(&:amount) }
                               }
    @latest_pos_import = current_user.business.pos_imports
                                     .where(id: @pos_transactions.map(&:pos_import_id).uniq)
                                     .order(updated_at: :desc).first
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
      @reconciliation.id,
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

  # GET /finance/daily_reconciliations/:id/edit_opening_float
  def edit_opening_float
    authorize @reconciliation, :update_opening_float_amounts?

    unless @reconciliation.blocked_by_opening_float?
      redirect_to finance_daily_reconciliation_path(@reconciliation) and return
    end

    load_edit_opening_float_data
  end

  # PATCH /finance/daily_reconciliations/:id/update_opening_float_amounts
  def update_opening_float_amounts
    authorize @reconciliation, :update_opening_float_amounts?

    result = Finance::OpeningFloatAmountsEditor.new(
      daily_reconciliation_id: @reconciliation.id,
      actor:                   current_user,
      amounts:                 params[:amounts]&.to_unsafe_h || {}
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.opening_float_amounts_saved")
    else
      load_edit_opening_float_data
      flash.now[:alert] = result.error
      render :edit_opening_float, status: :unprocessable_entity
    end
  end

  # POST /finance/daily_reconciliations/:id/receive_opening_float
  def receive_opening_float
    authorize @reconciliation, :receive_opening_float?

    result = Finance::OpeningFloatReceiver.new(
      daily_reconciliation_id: @reconciliation.id,
      actor:                   current_user
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.opening_float_received")
    else
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: result.error
    end
  end

  # GET /finance/daily_reconciliations/:id/correct_opening_float
  def correct_opening_float
    authorize @reconciliation, :correct_opening_float?

    unless @reconciliation.open? && @reconciliation.opening_float_source_handover_id.present?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: t("finance.daily_reconciliations.errors.correction_not_open")
      return
    end

    @opening_receipt = @reconciliation.till_handovers
                                      .peer.accepted
                                      .includes(amounts: :payment_method)
                                      .order(:created_at)
                                      .first

    if @opening_receipt.nil?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: t("finance.daily_reconciliations.errors.correction_no_opening_float")
      return
    end

    if @opening_receipt.superseded?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: t("finance.daily_reconciliations.errors.correction_already_corrected")
      return
    end

    @current_amounts = @opening_receipt.amounts.operational
                                       .includes(:payment_method)
                                       .order("payment_methods.position")
  end

  # PATCH /finance/daily_reconciliations/:id/update_opening_float_correction
  def update_opening_float_correction
    authorize @reconciliation, :correct_opening_float?

    result = Finance::OpeningFloatCorrector.new(
      daily_reconciliation_id: @reconciliation.id,
      actor:                   current_user,
      amounts:                 params[:amounts]&.to_unsafe_h || {},
      correction_reason:       params[:correction_reason]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.opening_float_correction_applied")
    else
      @opening_receipt = @reconciliation.till_handovers
                                        .peer.accepted
                                        .includes(amounts: :payment_method)
                                        .order(:created_at)
                                        .first
      @current_amounts = @opening_receipt&.amounts&.operational
                                         &.includes(:payment_method)
                                         &.order("payment_methods.position") || []
      flash.now[:alert] = result.error
      render :correct_opening_float, status: :unprocessable_entity
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

    result = Finance::DepositorAssigner.new(
      @reconciliation.id,
      actor:        current_user,
      depositor_id: params[:depositor_id]
    ).call

    if result.ok?
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  notice: t("finance.daily_reconciliations.depositor_assigned")
    else
      redirect_to finance_daily_reconciliation_path(@reconciliation),
                  alert: result.error
    end
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
      if h.self_deposit? && h.opening_float_declaration?
        # A standalone "Leave Opening Float" action recorded after day close.
        if h.seeded_daily_reconciliation.present?
          events << { type: :opening_float_left, time: h.created_at, actor: h.from_user,
                      data: h.seeded_daily_reconciliation }
        end
      elsif h.self_deposit?
        events << { type: :day_closed, time: h.created_at, actor: h.from_user, data: h }
        # If this self-deposit seeded the next day's DR, record the prepared event.
        # Pass the seeded DR (not the handover) so the view can display its business_date.
        if h.seeded_daily_reconciliation.present?
          events << { type: :opening_float_prepared, time: h.created_at, actor: h.from_user,
                      data: h.seeded_daily_reconciliation }
        end
      elsif h == opening_receipt_handover
        events << { type: :opening_float_received, time: h.accepted_at, actor: h.to_user, data: h } if h.accepted?
        events << { type: :opening_float_superseded, time: h.superseded_at, actor: h.superseded_by, data: h } if h.superseded?
      elsif h.correction?
        events << { type: :opening_float_corrected, time: h.accepted_at, actor: h.to_user, data: h }
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

  def load_edit_opening_float_data
    @source_handover = @reconciliation.opening_float_source_handover
    source_amounts   = @source_handover&.amounts&.next_day&.includes(:payment_method)&.to_a || []
    source_by_pm_id  = source_amounts.index_by(&:payment_method_id)

    all_pms = PaymentMethod.active.ordered
                           .where(business_id: @reconciliation.business_id)
                           .to_a

    override_by_pm_id = (@reconciliation.opening_float_override_amounts || [])
                          .index_by { |o| o["payment_method_id"].to_i }

    # One row per active PM: pre-filled from override > source > 0
    @edit_rows = all_pms.map do |pm|
      src = source_by_pm_id[pm.id]
      ov  = override_by_pm_id[pm.id]
      {
        payment_method:   pm,
        source_amount_id: src&.id,
        collected:        ov ? ov["collected_amount"].to_d : (src&.collected_amount || 0),
        refund:           ov ? ov["refund_amount"].to_d    : (src&.refund_amount || 0)
      }
    end
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
    params.permit(:status, :branch_id, :business_date, :verification_status)
  end

  def deposit_verification_status_for(dr)
    active_deposits = dr.till_deposits.reject(&:voided?)
    return :no_deposits if active_deposits.empty?

    transactions = active_deposits.map(&:bank_statement_transaction).compact
    return :not_imported if transactions.empty?

    if transactions.any? { |t| t.needs_reverification? }
      :needs_reverification
    elsif transactions.all? { |t| t.verified? }
      :verified
    else
      :pending
    end
  end
  helper_method :deposit_verification_status_for
end
