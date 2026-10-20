class Finance::DashboardController < Finance::BaseController
  # Executive finance overview. Every figure is policy-scoped (a branch manager
  # sees only their branches' data) and further narrowed by the unified filter
  # bar (Finance::DashboardFilters). Widgets that depend on data models this
  # app doesn't have yet (multi-business, supplier financials, cash/bank
  # ledgers) are gated by Finance::Dashboard::Capabilities and simply absent
  # from @capabilities-driven sections — never shown as placeholders.
  #
  # Revenue/Net-Profit/Margin reuse Finance::Reports::BranchProfitability,
  # which is monthly-granularity data (BranchRevenue is entered per branch per
  # month) — those three cards always reflect the calendar month containing
  # the filter bar's "to" date, compared against the prior calendar month,
  # regardless of how wide a date range is otherwise selected. Every other
  # widget honours the filter bar's date range directly.
  def index
    authorize :"finance/dashboard", :index?

    @capabilities = Finance::Dashboard::Capabilities.new
    @filters      = Finance::DashboardFilters.new(current_user, params).resolve
    @focus_month  = @filters.to.beginning_of_month
    # Revenue (BranchRevenue) and branch profitability (Finance::Reports::BranchProfitability)
    # were only ever surfaced through the view_expense_reports-gated report before this
    # redesign — every KPI/chart/insight derived from them must stay behind that same gate.
    @show_profitability = current_user.can?(:view_expense_reports)

    load_kpis
    load_trend
    load_distributions
    load_branch_profitability
    load_top_categories
    load_alerts
    load_cash_flow
    load_custody_summary
    load_recent_activity
    load_insights
  end

  def export_pdf
    index
    html = render_to_string(template: "finance/dashboard/export_pdf", layout: "pdf")
    send_data Finance::Dashboard::PdfRenderer.render(html),
              filename: "finance-dashboard-#{Date.current.iso8601}.pdf", type: "application/pdf", disposition: "attachment"
  end

  private

  # ── KPI cards ────────────────────────────────────────────────────────────

  def load_kpis
    @kpi_expenses = period_over_period(->(from, to) { expenses_by_category(from, to).values.sum(0) })

    if @show_profitability
      @kpi_revenue                = period_over_period(->(from, to) { verified_revenue(from, to).total })
      @kpi_profitability          = profitability_for(@focus_month)
      @kpi_profitability_previous = profitability_for(@focus_month - 1.month)
      # Net profit (and margin) reveal payroll cost: shown only when the viewer
      # may see the payroll cost of every branch in view (Finance::PayrollCostAccess).
      @show_net_profit = !@kpi_profitability[:net].nil?

      # Shared "is there any verified-DR revenue at all" checks, reused by
      # every revenue-dependent widget (Revenue by Branch, Branch
      # Profitability chart) so none of them render a misleadingly-populated
      # chart (e.g. an all-zero bar chart) when the answer is "no data yet" —
      # and so none of them re-derive this from scratch. Two checks because
      # the filter-bar date range and the profitability chart's calendar
      # month (@focus_month) are intentionally different scopes (see class
      # comment above).
      #
      # The focus-month check reads the 12-month trend's by_month (fetched
      # anyway by load_trend, same scope) — a month key exists iff a verified
      # row exists in that month, which is exactly what any? answers.
      @has_period_revenue      = verified_revenue(@filters.from, @filters.to).any?
      @has_focus_month_revenue = trend_revenue_by_month.key?(@focus_month)
    end

    @show_custody = current_user.can?(:view_employee_balances) || current_user.can?(:manage_employee_balances)
    if @show_custody
      @kpi_custody_balance = period_over_period(->(_from, to) { custody_balance_as_of(to) }, snapshot: true)
    end

    @show_supplier_kpi = @capabilities.supplier_financials_available?
    @show_cash_kpi     = @capabilities.cash_ledger_available?
    @show_bank_kpi     = @capabilities.bank_ledger_available?
  end

  # Runs `metric` for the current and previous period of equal length and
  # returns [current, previous]. `snapshot: true` treats `metric` as an
  # as-of-date balance rather than a period sum (previous = balance at the
  # end of the previous period, not a delta over it).
  def period_over_period(metric, snapshot: false)
    previous_from, previous_to = previous_period

    current  = metric.call(@filters.from, @filters.to)
    previous = snapshot ? metric.call(nil, previous_to) : metric.call(previous_from, previous_to)
    [ current, previous ]
  end

  # The equal-length period immediately before the filter bar's range.
  def previous_period
    previous_to = @filters.from - 1.day
    [ previous_to - (@filters.to - @filters.from), previous_to ]
  end

  # payroll / net are nil when any branch in view withholds them.
  def profitability_for(month)
    rows = profitability_rows_for(month)
    %i[revenue payroll inventory expenses net].index_with do |k|
      rows.any? { |r| r[k].nil? } ? nil : rows.sum { |r| r[k] }
    end
  end

  # Memoized per month so the KPI cards (revenue/net/margin) and the branch
  # profitability chart — both scoped to @focus_month — share one
  # Finance::Reports::BranchProfitability run instead of duplicating its
  # five grouped queries.
  def profitability_rows_for(month)
    @profitability_rows_by_month ||= {}
    @profitability_rows_by_month[month] ||= begin
      table = Finance::Reports::BranchProfitability.new(current_user.business, year: month.year, month: month.month,
                                                        payroll_branch_ids: payroll_branch_ids).call
      table.rows.select { |r| branch_names_by_id.value?(r[:branch]) }
    end
  end

  # id => name for every branch in scope, cached business-wide (branch lists
  # rarely change) so every dashboard request for the same business shares
  # one query, then narrowed in-memory to the current filter's branch_ids.
  # Every section that needs a branch label (distribution charts, insights,
  # profitability filtering) reads from this single memoized/cached map
  # instead of re-querying per section.
  def branch_names_by_id
    @branch_names_by_id ||= all_branch_names_by_id.slice(*@filters.branch_ids)
  end

  def all_branch_names_by_id
    Rails.cache.fetch("finance_dashboard/branch_names/#{current_user.business_id}", expires_in: 5.minutes) do
      current_user.business.branches.pluck(:id, :name).to_h
    end
  end

  def expenses_scope(from, to)
    scope = policy_scope(Expense).where(status: "approved").in_period(from, to)
                                  .where(branch_id: [ nil ] + @filters.branch_ids)
    scope = scope.where(payment_source: @filters.payment_source) if @filters.payment_source
    scope
  end

  # Approved expenses in the period, summed per category name — memoized per
  # period so the Expenses KPI (current + previous total), the category
  # distribution and the top-categories trend share one grouped query per
  # period. Summing every group equals SUM(amount) over expenses_scope:
  # expense_category_id is NOT NULL with a foreign key, so the inner join
  # neither drops nor duplicates an expense.
  def expenses_by_category(from, to)
    @expenses_by_category ||= {}
    @expenses_by_category[[ from, to ]] ||= expenses_scope(from, to).joins(:expense_category)
                                              .group("expense_categories.name").sum(:amount)
  end

  # Finance::Reports::VerifiedRevenue is the single source of truth for
  # revenue across the whole Finance module (dashboard + Branch Profitability
  # report) — SUM(TillSessionAmount.net_amount) for verified Daily
  # Reconciliations only. Never read BranchRevenue or SalesTransaction here.
  #
  # Memoized per period: VerifiedRevenue memoizes its own grouped results, so
  # the Revenue KPI, the has-data check and Revenue by Branch for the same
  # range share a single query.
  def verified_revenue(from, to)
    @verified_revenue ||= {}
    @verified_revenue[[ from, to ]] ||=
      Finance::Reports::VerifiedRevenue.new(current_user.business, from: from, to: to, branch_ids: @filters.branch_ids)
  end

  def custody_balance_as_of(date)
    accounts = policy_scope(CustodyAccount).where(branch_id: @filters.branch_ids)
    accounts = accounts.where(user_id: @filters.cashier_id) if @filters.cashier_id
    CustodyTransaction.active.where(custody_account_id: accounts.select(:id))
                       .where(created_at: ..date.end_of_day).sum(:amount)
  end

  # ── Revenue / Expense / Net trend (monthly; client aggregates to quarter/year) ──

  # The trailing 12 calendar months ending with @focus_month.
  def trend_months
    @trend_months ||= 11.downto(0).map { |n| @focus_month - n.months }
  end

  def trend_revenue_by_month
    verified_revenue(trend_months.first.beginning_of_month, trend_months.last.end_of_month).by_month
  end

  def load_trend
    months = trend_months
    # Keys normalized to Date for the same reason as VerifiedRevenue#by_month —
    # date_trunc() grouping keys come back as Time, which never #eql? the Date
    # objects in `months`, so the lookups below would silently always miss.
    expenses = expenses_scope(months.first.beginning_of_month, months.last.end_of_month)
                 .group(Arel.sql("date_trunc('month', expense_date)")).sum(:amount)
                 .transform_keys(&:to_date)

    @trend_labels   = months.map { |m| I18n.l(m, format: "%b %Y") }
    # .to_f so every element is a plain float (BigDecimal serializes to a JSON
    # string, not a number, which the chart JS would receive as mixed types).
    @trend_expenses = months.map { |m| (expenses[m] || 0).to_f }
    # Reshaping of the same `months` array above — lets the trend chart turn a
    # clicked point into "view the dashboard filtered to that month" without
    # a second query or a new calculation.
    @trend_month_bounds = months.map { |m| [ m.beginning_of_month, m.end_of_month ] }

    return unless @show_profitability

    revenue = trend_revenue_by_month
    @trend_revenue = months.map { |m| (revenue[m] || 0).to_f }
    @trend_net     = @trend_revenue.zip(@trend_expenses).map { |r, e| r - e }
  end

  # ── Distribution charts ─────────────────────────────────────────────────

  def load_distributions
    @by_category = expenses_by_category(@filters.from, @filters.to).sort_by { |_, total| -total }.first(8)
    @category_ids_by_name = Rails.cache.fetch("finance_dashboard/expense_categories/#{current_user.business_id}", expires_in: 5.minutes) do
      current_user.business.expense_categories.pluck(:name, :id).to_h
    end

    return unless @show_profitability

    # id kept alongside name/total (not just [name, total]) so the doughnut
    # chart can turn a click into "filter the dashboard by this branch" —
    # same values already fetched, just not discarded.
    @revenue_by_branch = verified_revenue(@filters.from, @filters.to).by_branch
                           .filter_map { |id, total| [ id, branch_names_by_id[id], total ] if branch_names_by_id[id] }
                           .sort_by { |_, _, total| -total }.first(8)
  end

  # ── Branch profitability (bar chart) ────────────────────────────────────

  def load_branch_profitability
    return unless @show_profitability

    @profitability = profitability_rows_for(@focus_month)
  end

  # ── Top expense categories with period-over-period trend ───────────────

  def load_top_categories
    previous_by_category = expenses_by_category(*previous_period)

    total = @by_category.sum { |_, amount| amount }
    @top_categories = @by_category.first(10).map do |name, amount|
      prev   = previous_by_category[name].to_f
      change = prev.zero? ? nil : (amount.to_f - prev) / prev
      { name: name, amount: amount, pct: total.zero? ? 0 : (amount / total * 100), change: change }
    end
    @by_category_previous = previous_by_category
  end

  # ── Alerts ───────────────────────────────────────────────────────────────

  def load_alerts
    expenses = policy_scope(Expense).where(branch_id: [ nil ] + @filters.branch_ids)
    @alert_pending_count = expenses.pending.count
    @alert_pending        = expenses.pending.recent.includes(:branch, :expense_category).limit(5)

    @show_recurring = current_user.can?(:view_expenses) || current_user.can?(:manage_recurring_expenses)
    if @show_recurring
      @alert_recurring = policy_scope(RecurringExpense).active.where(branch_id: [ nil ] + @filters.branch_ids)
                            .where(next_run_on: ..30.days.from_now.to_date)
                            .includes(:expense_category, :branch).ordered.limit(5)
    end

    @show_outstanding = current_user.can?(:settle_remaining_deposit_balance) || current_user.can?(:view_daily_reconciliation)
    if @show_outstanding
      overdue_days      = current_user.business.finance_overdue_days
      notify_thresholds = current_user.business.finance_notify_thresholds
      open_rdb          = policy_scope(RemainingDepositBalance).where(branch_id: @filters.branch_ids).open
      # The alerts panel only shows counts/links, never per-row detail — and
      # every figure is a filter over the same open set, so one aggregate row
      # answers all of them: open count, open amount, then one age-cutoff
      # count per bucket (the overdue window first, then each notify
      # threshold). Same predicate as RemainingDepositBalance.overdue.
      cutoffs = [ overdue_days, *notify_thresholds ].map do |days|
        Arel.sql(RemainingDepositBalance.sanitize_sql_array(
          [ "COUNT(*) FILTER (WHERE remaining_deposit_balances.created_at < ?)", days.days.ago ]
        ))
      end
      open_count, open_amount, overdue_count, *threshold_counts =
        open_rdb.pick(Arel.sql("COUNT(*)"), Arel.sql("SUM(remaining_deposit_balances.remaining_amount)"), *cutoffs)

      @rdb_open_count    = open_count
      @rdb_open_amount   = open_amount || 0
      @rdb_overdue_count = overdue_count
      @rdb_overdue_days  = overdue_days
      @rdb_threshold_alerts = notify_thresholds.zip(threshold_counts).filter_map do |days, count|
        { days: days, count: count } if count > 0
      end
    end

    if @show_custody
      @alert_negative_custody = custody_rows.select { |row| row[:balance].negative? }.sort_by { |row| row[:balance] }.first(5)
    end
  end

  # ── Cash flow (Custody Top-ups vs Bank Deposits, custody spend as outflow) ──

  def load_cash_flow
    return unless @show_custody

    accounts = policy_scope(CustodyAccount).where(branch_id: @filters.branch_ids)
    accounts = accounts.where(user_id: @filters.cashier_id) if @filters.cashier_id

    ledger = CustodyTransaction.active.where(custody_account_id: accounts.select(:id))
                                .where(created_at: @filters.from.beginning_of_day..@filters.to.end_of_day)

    # One pass over the ledger: per business-local calendar day (the same
    # day boundaries as the created_at range above, which is built in the
    # business time zone), inflows and outflows summed separately so the
    # period totals come from the same rows. Bucketing in SQL by local date —
    # rather than date_trunc on the UTC timestamp — keeps early-morning
    # transactions on the right day and yields plain Date keys that match
    # the Date lookups below regardless of the server's own TZ.
    local_day = Arel.sql(CustodyTransaction.sanitize_sql_array(
      [ "(custody_transactions.created_at AT TIME ZONE 'UTC' AT TIME ZONE ?)::date", Time.zone.tzinfo.identifier ]
    ))
    rows = ledger.group(local_day).pluck(local_day,
                                         Arel.sql("SUM(custody_transactions.amount) FILTER (WHERE custody_transactions.amount > 0)"),
                                         Arel.sql("SUM(custody_transactions.amount) FILTER (WHERE custody_transactions.amount < 0)"))
    by_day = rows.to_h { |day, inflow, outflow| [ day, (inflow || 0) + (outflow || 0) ] }
    days   = (@filters.from..@filters.to).to_a

    @cash_flow_labels = days.map { |d| I18n.l(d, format: :long) }
    @cash_flow_net    = days.map { |d| by_day[d] || 0 }
    @cash_in          = rows.sum(0) { |_, inflow, _| inflow || 0 }
    @cash_out          = rows.sum(0) { |_, _, outflow| outflow || 0 }.abs
    @cash_net          = @cash_in - @cash_out
  end

  # ── Custody summary ──────────────────────────────────────────────────────

  def load_custody_summary
    return unless @show_custody

    @custody_positive_count = custody_rows.count { |r| r[:balance].positive? }
    @custody_negative_count = custody_rows.count { |r| r[:balance].negative? }
    @custody_top5 = custody_rows.sort_by { |r| -r[:balance] }.first(5)
  end

  # Active custody accounts (+ current balances) in the filtered scope,
  # memoized so the negative-balance alert (load_alerts) and the custody
  # summary counts/top-5 (load_custody_summary) share one query pair instead
  # of each independently loading accounts + summing their ledgers.
  def custody_rows
    @custody_rows ||= begin
      accounts = policy_scope(CustodyAccount).active.where(branch_id: @filters.branch_ids).includes(:user)
      accounts = accounts.where(user_id: @filters.cashier_id) if @filters.cashier_id
      balances = CustodyTransaction.active.where(custody_account_id: accounts.map(&:id)).group(:custody_account_id).sum(:amount)
      accounts.map { |a| { name: a.name, holder: a.user.full_name, balance: balances[a.id] || 0 } }
    end
  end

  # ── Recent activity (AuditLog) ──────────────────────────────────────────

  RECENT_ACTIVITY_TYPES = %w[Expense TillDeposit CustodyTransaction RemainingDepositBalance].freeze

  def load_recent_activity
    @recent_activity = AuditLog.for_business(current_user.business)
                                .where(auditable_type: RECENT_ACTIVITY_TYPES)
                                .includes(:actor, :auditable).recent.limit(10)
  end

  # ── Smart insights ───────────────────────────────────────────────────────

  def load_insights
    by_branch = expenses_scope(@filters.from, @filters.to).group(:branch_id).sum(:amount)
                  .map { |id, total| [ id ? branch_names_by_id[id] : t("finance.expenses.shared"), total ] }.to_h

    @insights = Finance::Dashboard::InsightsGenerator.new(
      by_category: @by_category.to_h,
      by_category_previous: @by_category_previous,
      by_branch: by_branch,
      total_expenses: @kpi_expenses.first,
      # Payroll share, operating cost and best/worst branch by net all derive
      # from payroll cost — only when it is shown for every branch in view.
      payroll_cost: @show_net_profit ? @kpi_profitability[:payroll] : nil,
      operating_cost: @show_net_profit ? @kpi_profitability.values_at(:payroll, :inventory, :expenses).sum : nil,
      profitability_rows: @show_net_profit ? @profitability : nil
    ).insights
  end

  # Branches whose payroll cost the viewer may see (view_payroll + its scope).
  def payroll_branch_ids
    @payroll_branch_ids ||= Finance::PayrollCostAccess.new(current_user).branch_ids
  end
end
