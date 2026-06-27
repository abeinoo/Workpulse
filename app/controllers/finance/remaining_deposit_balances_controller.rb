require "csv"

class Finance::RemainingDepositBalancesController < Finance::BaseController
  before_action :set_balance,    only: %i[show settle write_off reassign]
  before_action :set_business,   only: %i[index export bulk_settle employee_profile]

  # GET /finance/remaining_deposit_balances
  def index
    authorize RemainingDepositBalance, :index?

    base = policy_scope(RemainingDepositBalance)
             .includes(:daily_reconciliation, :responsible_user,
                        till_deposit:         :payment_method,
                        daily_reconciliation: :branch)

    overdue_cutoff = @business.finance_overdue_days.days.ago

    # ── Summary figures (always full scope) ───────────────────────────────
    @open_count        = base.open.count
    @total_outstanding = base.open.sum(:remaining_amount)
    @overdue_count     = base.open.where("remaining_deposit_balances.created_at < ?", overdue_cutoff).count
    @oldest_open_at    = base.open.minimum(:created_at)
    @oldest_days       = @oldest_open_at ? ((Time.current - @oldest_open_at) / 1.day).to_i : nil
    avg_secs           = base.open.average(
      Arel.sql("EXTRACT(EPOCH FROM (NOW() - remaining_deposit_balances.created_at))")
    )
    @avg_days_open     = avg_secs ? (avg_secs / 86400.0).round(1) : nil

    # ── Status filter ─────────────────────────────────────────────────────
    @status_filter = params[:status].presence_in(%w[open settled written_off all]) || "open"
    scope = @status_filter == "all" ? base : base.where(status: @status_filter)

    # ── Quick filters ─────────────────────────────────────────────────────
    @quick_filter = params[:quick].presence_in(%w[overdue today this_week]) || nil
    scope = case @quick_filter
            when "overdue"   then scope.open.where("remaining_deposit_balances.created_at < ?", overdue_cutoff)
            when "today"     then scope.where("remaining_deposit_balances.created_at >= ?", Time.current.beginning_of_day)
            when "this_week" then scope.where("remaining_deposit_balances.created_at >= ?", Time.current.beginning_of_week)
            else scope
            end

    @branch_filter   = params[:branch_id].presence
    @employee_filter = params[:responsible_user_id].presence
    scope = scope.where(branch_id:           @branch_filter)   if @branch_filter
    scope = scope.where(responsible_user_id: @employee_filter) if @employee_filter

    @balances  = scope.ordered
    @branches  = current_user.business.branches.active.order(:name)
    @employees = current_user.business.users.active.order(:first_name)
  end

  # GET /finance/remaining_deposit_balances/export
  def export
    authorize RemainingDepositBalance, :index?

    base  = policy_scope(RemainingDepositBalance)
              .includes(:daily_reconciliation, :responsible_user, :created_by,
                         till_deposit:         :payment_method,
                         daily_reconciliation: :branch)

    status_filter = params[:status].presence_in(%w[open settled written_off all]) || "open"
    scope = status_filter == "all" ? base : base.where(status: status_filter)

    quick = params[:quick].presence_in(%w[overdue today this_week])
    scope = case quick
            when "overdue"   then scope.open.where("remaining_deposit_balances.created_at < ?", @business.finance_overdue_days.days.ago)
            when "today"     then scope.where("remaining_deposit_balances.created_at >= ?", Time.current.beginning_of_day)
            when "this_week" then scope.where("remaining_deposit_balances.created_at >= ?", Time.current.beginning_of_week)
            else scope
            end

    scope = scope.where(branch_id: params[:branch_id])                       if params[:branch_id].present?
    scope = scope.where(responsible_user_id: params[:responsible_user_id])   if params[:responsible_user_id].present?

    if params[:balance_ids].present?
      scope = scope.where(id: params[:balance_ids].to_s.split(",").map(&:to_i))
    end

    balances = scope.ordered

    csv_data = CSV.generate(headers: true) do |csv|
      csv << %w[Branch Employee BusinessDate PaymentMethod Expected Deposited Outstanding
                Status ResponsibleUser Age(days) ClosedBy ClosedDate Notes]
      balances.each do |b|
        dr          = b.daily_reconciliation
        deposited   = b.till_deposit&.amount || 0
        expected    = deposited + b.amount
        age_days    = ((Time.current - b.created_at) / 1.day).to_i
        closed_by   = b.closed? ? b.closed_by&.full_name : ""
        closed_date = b.closed_at ? b.closed_at.to_date.to_s : ""

        csv << [
          dr.branch.name,
          b.responsible_user.full_name,
          (dr.business_date || dr.opened_at.to_date).to_s,
          b.till_deposit&.payment_method&.display_name,
          expected.to_f.round(2),
          deposited.to_f.round(2),
          b.remaining_amount.to_f.round(2),
          b.status,
          b.responsible_user.full_name,
          age_days,
          closed_by,
          closed_date,
          b.balance_transactions.ordered.last&.notes
        ]
      end
    end

    filename = "outstanding_balances_#{Date.today}.csv"
    send_data csv_data, filename: filename, type: "text/csv", disposition: "attachment"
  end

  # POST /finance/remaining_deposit_balances/bulk_settle
  def bulk_settle
    authorize RemainingDepositBalance, :settle?

    ids      = Array(params[:balance_ids]).flat_map { |s| s.to_s.split(",") }.map(&:to_i).uniq
    balances = policy_scope(RemainingDepositBalance).open.where(id: ids)

    if balances.none?
      return redirect_to finance_remaining_deposit_balances_path,
                         alert: t("remaining_deposit_balances.bulk.none_selected")
    end

    success_count = 0
    error_ids     = []

    balances.each do |balance|
      result = Finance::RemainingDepositBalanceSettler.new(
        balance,
        actor:             current_user,
        amount:            balance.remaining_amount,
        payment_method_id: params[:payment_method_id].presence,
        notes:             params[:notes].presence || t("remaining_deposit_balances.bulk.auto_note")
      ).call
      result.ok? ? success_count += 1 : error_ids << balance.id
    end

    notice = t("remaining_deposit_balances.bulk.settled_count", count: success_count)
    notice += " #{t('remaining_deposit_balances.bulk.failed_ids', ids: error_ids.join(', '))}" if error_ids.any?
    redirect_to finance_remaining_deposit_balances_path, notice: notice
  end

  # GET /finance/remaining_deposit_balances/employee_profile?user_id=X
  def employee_profile
    authorize RemainingDepositBalance, :index?

    @user = current_user.business.users.find(params[:user_id])
    base  = policy_scope(RemainingDepositBalance).where(responsible_user_id: @user.id)

    @total_incidents   = base.count
    @open_count        = base.open.count
    @total_outstanding = base.open.sum(:remaining_amount)
    @total_amount      = base.sum(:amount)
    @total_settled     = base.settled.sum(:amount)
    @total_written_off = base.written_off.sum(:amount)
    @largest_shortage  = base.maximum(:amount) || 0
    @last_shortage_at  = base.maximum(:created_at)

    avg_secs = base.settled
                   .where("closed_at IS NOT NULL")
                   .average(Arel.sql("EXTRACT(EPOCH FROM (closed_at - remaining_deposit_balances.created_at))"))
    @avg_settlement_days = avg_secs ? (avg_secs / 86400.0).round(1) : nil

    @balances = base.includes(:daily_reconciliation, :responsible_user, :created_by,
                               till_deposit:         :payment_method,
                               daily_reconciliation: :branch)
                    .ordered
  end

  # GET /finance/remaining_deposit_balances/:id
  def show
    authorize @balance
    if @balance.open?
      @business_users  = current_user.business.users.active.order(:first_name)
      @payment_methods = business_payment_methods
    end
  end

  # PATCH /finance/remaining_deposit_balances/:id/settle
  def settle
    authorize @balance

    result = Finance::RemainingDepositBalanceSettler.new(
      @balance,
      actor:             current_user,
      amount:            params[:amount],
      notes:             params[:notes],
      payment_method_id: params[:payment_method_id],
      reference_number:  params[:reference_number]
    ).call

    if result.ok?
      notice = result.balance.open? ? t("remaining_deposit_balances.partial_settled") : t("remaining_deposit_balances.settled")
      redirect_to finance_remaining_deposit_balance_path(@balance), notice: notice
    else
      flash.now[:alert]  = result.error
      @business_users    = current_user.business.users.active.order(:first_name)
      @payment_methods   = business_payment_methods
      render :show, status: :unprocessable_entity
    end
  end

  # PATCH /finance/remaining_deposit_balances/:id/write_off
  def write_off
    authorize @balance, :write_off?

    result = Finance::RemainingDepositBalanceWriteOff.new(
      @balance,
      actor:  current_user,
      notes:  params[:notes]
    ).call

    if result.ok?
      redirect_to finance_remaining_deposit_balance_path(@balance),
                  notice: t("remaining_deposit_balances.written_off")
    else
      flash.now[:alert]  = result.error
      @business_users    = current_user.business.users.active.order(:first_name)
      @payment_methods   = business_payment_methods
      render :show, status: :unprocessable_entity
    end
  end

  # PATCH /finance/remaining_deposit_balances/:id/reassign
  def reassign
    authorize @balance, :reassign?

    new_user = current_user.business.users.active.find(params[:new_responsible_user_id])
    result   = Finance::RemainingDepositBalanceReassigner.new(
      @balance,
      actor:    current_user,
      new_user: new_user,
      notes:    params[:notes]
    ).call

    if result.ok?
      redirect_to finance_remaining_deposit_balance_path(@balance),
                  notice: t("remaining_deposit_balances.reassigned")
    else
      flash.now[:alert]  = result.error
      @business_users    = current_user.business.users.active.order(:first_name)
      @payment_methods   = business_payment_methods
      render :show, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to finance_remaining_deposit_balance_path(@balance),
                alert: t("remaining_deposit_balances.errors.invalid_user")
  end

  private

  def set_balance
    @balance = policy_scope(RemainingDepositBalance)
                 .includes(:daily_reconciliation, :responsible_user, :created_by,
                            till_deposit:          :payment_method,
                            daily_reconciliation:  :branch,
                            balance_transactions:  %i[performed_by
                                                       previous_responsible_user
                                                       new_responsible_user
                                                       payment_method])
                 .find(params[:id])
  end

  def set_business
    @business = current_user.business
  end
end
