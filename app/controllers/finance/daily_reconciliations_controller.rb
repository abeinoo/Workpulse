class Finance::DailyReconciliationsController < Finance::BaseController
  before_action :set_reconciliation, only: %i[show verify assign_depositor]

  # GET /finance/daily_reconciliations
  def index
    authorize DailyReconciliation

    query = DailyReconciliation
              .where(business_id: current_user.business_id)
              .includes(:branch,
                        till_session: %i[current_holder depositor])
              .order(opened_at: :desc)
              .limit(60)

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

    @reconciliations = query
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
                                .includes(:from_user, :to_user, amounts: :payment_method)
                                .order(:created_at)
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

    @employee_summaries  = Finance::EmployeeReconciliationSummarizer.new(@reconciliation).summaries
    @timeline_events     = build_timeline_events
  end

  # POST /finance/daily_reconciliations
  def create
    authorize DailyReconciliation, :create?

    branch = resolve_branch
    return unless branch

    today = Date.current

    open_recon = DailyReconciliation.open_for(branch)
    if open_recon
      return redirect_to finance_daily_reconciliation_path(open_recon),
                         notice: t("finance.daily_reconciliations.errors.already_exists")
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

  # PATCH /finance/daily_reconciliations/:id/assign_depositor
  def assign_depositor
    authorize @reconciliation, :assign_depositor?

    if @reconciliation.deposit_responsibility_transfers.pending.exists?
      return redirect_to finance_daily_reconciliation_path(@reconciliation),
                         alert: t("finance.daily_reconciliations.errors.pending_transfer_exists")
    end

    depositor = current_user.business.users.active.find(params[:depositor_id])
    @reconciliation.till_session.update!(depositor: depositor)
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

    @handovers.each do |h|
      if h.self_deposit?
        events << { type: :day_closed,        time: h.created_at,  actor: h.from_user, data: h }
      else
        events << { type: :handover_created,  time: h.created_at,  actor: h.from_user, data: h }
        events << { type: :handover_accepted, time: h.accepted_at, actor: h.to_user,   data: h } if h.accepted?
      end
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

    if @reconciliation.verified?
      events << { type: :day_verified, time: @reconciliation.verified_at,
                  actor: @reconciliation.verified_by, data: @reconciliation }
    end

    events.sort_by! { |e| e[:time] }
  end

  def set_reconciliation
    @reconciliation = policy_scope(DailyReconciliation)
                        .includes(:branch, :business, :verified_by,
                                  session_amounts: :payment_method,
                                  till_session:    %i[depositor closed_by current_holder])
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

    if scope_name
      ids = BranchScope.new(current_user).for_scope(scope_name)
      if ids.empty? && scope_name != "business"
        shift_branch = current_user.shift_assignments.current.first&.branch
        return shift_branch ? [shift_branch] : []
      end
      return current_user.business.branches.active.where(id: ids).order(:name).to_a
    end

    shift_branch = current_user.shift_assignments.current.first&.branch
    shift_branch ? [shift_branch] : []
  end
end
