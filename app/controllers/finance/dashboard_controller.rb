class Finance::DashboardController < Finance::BaseController
  # Finance overview. Every figure is policy-scoped (a branch manager sees only
  # their branches' data) and custody/recurring widgets are permission-gated.
  def index
    expenses = policy_scope(Expense)
    month    = Date.current.beginning_of_month..Date.current.end_of_month
    committed = expenses.where(status: "approved").in_period(month.first, month.last)

    @pending_count = expenses.pending.count
    @pending       = expenses.pending.recent.includes(:branch, :expense_category).limit(8)
    @month_total   = committed.sum(:amount)

    @by_category = committed.joins(:expense_category)
                            .group("expense_categories.name").sum(:amount)
                            .sort_by { |_, total| -total }.first(6)
    @by_branch   = by_branch(committed)

    @show_custody = current_user.can?(:view_employee_balances) || current_user.can?(:manage_employee_balances)
    @outstanding  = outstanding_custody if @show_custody

    @show_recurring    = current_user.can?(:view_expenses) || current_user.can?(:manage_recurring_expenses)
    @upcoming_recurring = upcoming_recurring if @show_recurring

    # Outstanding deposit balances — visible to anyone who can settle or view DRs.
    @show_outstanding = current_user.can?(:settle_remaining_deposit_balance) ||
                        current_user.can?(:view_daily_reconciliation)
    if @show_outstanding
      overdue_days           = current_user.business.finance_overdue_days
      notify_thresholds      = current_user.business.finance_notify_thresholds
      all_rdb                = policy_scope(RemainingDepositBalance)
      @rdb_open_count        = all_rdb.open.count
      @rdb_open_amount       = all_rdb.open.sum(:remaining_amount)
      @rdb_overdue           = all_rdb.overdue(days: overdue_days)
                                      .includes(:responsible_user, daily_reconciliation: :branch)
                                      .order(:created_at).limit(10)
      @rdb_overdue_days      = overdue_days
      # Threshold alerts: count open balances that have passed each notification threshold
      @rdb_threshold_alerts  = notify_thresholds.map do |days|
        count = all_rdb.open.where("remaining_deposit_balances.created_at < ?", days.days.ago).count
        { days: days, count: count } if count > 0
      end.compact
      today                  = Time.current.beginning_of_day..Time.current.end_of_day
      business_rdb_ids       = all_rdb.pluck(:id)
      @rdb_settled_today     = RemainingDepositBalanceTransaction
                                 .where(remaining_deposit_balance_id: business_rdb_ids,
                                        transaction_type: "settlement", created_at: today)
                                 .sum(:amount)
      @rdb_written_off_today = RemainingDepositBalanceTransaction
                                 .where(remaining_deposit_balance_id: business_rdb_ids,
                                        transaction_type: "write_off", created_at: today)
                                 .sum(:amount)
    end

    # Branch profitability is business-wide reporting — same gate as the report.
    if current_user.can?(:view_expense_reports)
      @profitability = Finance::Reports::BranchProfitability.new(
        current_user.business, year: Date.current.year, month: Date.current.month
      ).call
    end
  end

  private

  # Committed spend per branch this month; NULL-branch (shared/business-level)
  # rolls into a single bucket. Shared allocations are summarised in the reports.
  def by_branch(committed)
    names = current_user.business.branches.pluck(:id, :name).to_h
    committed.group(:branch_id).sum(:amount)
             .map { |branch_id, total| [ branch_id ? names[branch_id] : t("finance.expenses.shared"), total ] }
             .sort_by { |_, total| -total }.first(6)
  end

  def outstanding_custody
    accounts = policy_scope(CustodyAccount).active.includes(:user)
    balances = CustodyTransaction.active.where(custody_account_id: accounts.map(&:id))
                                 .group(:custody_account_id).sum(:amount)
    accounts.filter_map do |account|
      balance = balances[account.id] || 0
      next if balance.zero?

      { name: account.name, holder: account.user.full_name, balance: balance }
    end.sort_by { |row| -row[:balance] }.first(6)
  end

  def upcoming_recurring
    policy_scope(RecurringExpense).active
      .where(next_run_on: ..30.days.from_now.to_date)
      .includes(:expense_category, :branch).ordered.limit(8)
  end
end
