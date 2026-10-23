class Finance::ReportsController < Finance::BaseController
  before_action :require_reports_access!

  def index; end

  # These four reports render their own dedicated (redesigned) templates and
  # load extra, presentation-only context — a previous-period run of the same
  # service, and row-level pct/change math over already-fetched totals — but
  # @table itself (and therefore the CSV export) is still produced by the
  # exact same Finance::Reports::ExpenseSummary / ExpenseTrend call as before.
  def expenses_by_branch
    range    = date_range
    table    = Finance::Reports::ExpenseSummary.new(business, group_by: :branch, **range).call
    previous = Finance::Reports::ExpenseSummary.new(business, group_by: :branch, **previous_range).call
    load_breakdown_context(table, previous)
    @drill_down_ids = business.branches.pluck(:name, :id).to_h
    render_report(table, template: :expenses_by_branch)
  end

  # By Category / By Type take the period-preset + branch filter bar
  # (Finance::Reports::ExpenseReportFilters). The page's KPIs, ranking, charts,
  # table and CSV all read the same validated @filters.
  def expenses_by_category
    filtered_expense_breakdown(:category)
    @drill_down_ids = business.expense_categories.pluck(:name, :id).to_h
    render_report(@breakdown_table, template: :expenses_by_category)
  end

  def expenses_by_type
    filtered_expense_breakdown(:type)
    @drill_down_ids = business.expense_types.pluck(:name, :id).to_h
    render_report(@breakdown_table, template: :expenses_by_type)
  end

  def expense_trend
    range           = date_range
    table           = Finance::Reports::ExpenseTrend.new(business, **range).call
    @previous_table = Finance::Reports::ExpenseTrend.new(business, **previous_range).call
    @moving_average = moving_average(table.rows.map { |r| r[:total].to_f }, window: 3)
    render_report(table, template: :expense_trend)
  end

  def shared_allocation    = render_report(Finance::Reports::SharedAllocation.new(business, **date_range).call)
  def recurring            = render_report(Finance::Reports::RecurringSummary.new(business).call)
  def custody_balances     = render_report(Finance::Reports::CustodyBalances.new(business).call)
  def custody_transactions = render_report(Finance::Reports::CustodyTransactions.new(business, **date_range).call)
  def negative_balances    = render_report(Finance::Reports::NegativeBalances.new(business).call)
  def approvals            = render_report(Finance::Reports::ApprovalReport.new(business, **date_range).call)

  def branch_profitability
    @year  = year
    @month = month
    # @table is exactly what CSV export has always used — untouched, and the
    # CSV action below still reads only @table, so the export is byte-for-byte
    # identical to before this page was redesigned.
    # Payroll cost (and net profit, which reveals it) only for the branches of
    # the viewer's view_payroll scope — the HTML, CSV and charts all read @table.
    @table          = Finance::Reports::BranchProfitability.new(business, year: @year, month: @month,
                                                                payroll_branch_ids: payroll_branch_ids).call
    previous_month  = Date.new(@year, @month, 1) - 1.month
    @previous_table = Finance::Reports::BranchProfitability.new(business, year: previous_month.year, month: previous_month.month,
                                                                payroll_branch_ids: payroll_branch_ids).call
    @payroll_restricted = @table.rows.any? { |row| row[:payroll].nil? }

    # Branch Profitability is a Sales-branch report (see Finance::Reports::
    # BranchProfitability) — narrowing the same assignable_branches collection
    # every other Finance page uses (not swapping it for a different query) so
    # a manually-submitted non-sales branch_id simply won't be found below and
    # falls through to the existing empty-selection handling, the same safe
    # behavior an inaccessible branch_id already gets.
    @accessible_branches = assignable_branches.where(branch_type: "sales")
    @branch_ids_by_name  = @accessible_branches.pluck(:name, :id).to_h
    @branch_rows         = branch_profitability_rows(@table.rows, @previous_table.rows)
    # Branches whose net profit is not shown (nil) rank last.
    @ranked_branch_rows  = @branch_rows.sort_by { |r| r[:net].nil? ? [ 1, 0 ] : [ 0, -r[:net] ] }

    @margin          = margin_pct(@table.totals[:net], @table.totals[:revenue])
    @previous_margin = margin_pct(@previous_table.totals[:net], @previous_table.totals[:revenue])

    @selected_branch_id = params[:branch_id].presence&.to_i
    if @selected_branch_id
      selected_name        = @accessible_branches.find { |b| b.id == @selected_branch_id }&.name
      @branch_rows          = @branch_rows.select { |r| r[:branch] == selected_name }
      @ranked_branch_rows   = @ranked_branch_rows.select { |r| r[:branch] == selected_name }
    end

    respond_to do |format|
      format.html { render :branch_profitability }
      format.csv  { send_csv(@table, "branch_profitability") }
    end
  end

  # Report section keys a user can narrow the page to via the "نوع المصروف"
  # filter — the report's own six logical sections, not the ExpenseType
  # model (see #expense_details). Purely a display filter: it never changes
  # what Finance::Reports::ExpenseDetails computes, only which of its
  # already-computed sections get rendered/exported, so it can never affect
  # totals, reconciliation, or double-count anything.
  SECTION_FILTER_KEYS = %w[payroll laundry inventory branch_expenses shared_expenses other].freeze

  # تقرير تفاصيل المصروفات — hierarchical drill-down into the same cost
  # sources Branch Profitability sums, via Finance::Reports::ExpenseDetails
  # (which in turn shares Finance::Reports::ExpenseSources with
  # BranchProfitability, so the two reports can never drift apart).
  #
  # Period resolution (single month / last N months / custom range) is
  # entirely Finance::Reports::PeriodResolver's job — a request with only
  # month=/year= (no period_type=) resolves to the exact same single-month
  # range the report has always used, so existing bookmarked URLs keep
  # working unchanged.
  def expense_details
    @period = Finance::Reports::PeriodResolver.call(params)
    if @period.valid?
      @period_error = nil
    else
      # Never run the report against an inverted/invalid range — fall back
      # to a plain single month (the "to" side of what was submitted, or the
      # current month) and surface the validation message instead.
      @period_error = @period.error
      @period = Finance::Reports::PeriodResolver.call(period_type: "single_month", year: @period.to_year.to_s, month: @period.to_month.to_s)
    end
    @year, @month = @period.to_year, @period.to_month

    @accessible_branches = assignable_branches.where(branch_type: "sales")
    @selected_branch_id  = params[:branch_id].presence&.to_i
    @expense_type_id     = params[:expense_type_id].presence&.to_i
    @selected_section     = params[:section].presence if SECTION_FILTER_KEYS.include?(params[:section])

    @result = Finance::Reports::ExpenseDetails.new(
      business, year: @period.from_year, month: @period.from_month,
      to_year: @period.to_year, to_month: @period.to_month,
      branch_id: @selected_branch_id, expense_type_id: @expense_type_id,
      payroll_branch_ids: payroll_branch_ids
    ).call
    @result.sections = @result.sections.select { |s| s.key == @selected_section.to_sym } if @selected_section
    shown_payroll_entries = restrict_payroll_rows!(@result)

    respond_to do |format|
      format.html do
        Payroll::EntryViewAudit.record(actor: current_user, entries: shown_payroll_entries, source: "finance_expense_details")
        render :expense_details
      end
      format.csv do
        csv = Finance::Reports::ExpenseDetailsCsvExporter.new(@result).to_csv
        Payroll::EntryViewAudit.record(actor: current_user, entries: shown_payroll_entries, source: "finance_expense_details_csv")
        send_data csv, filename: "expense_details_#{Date.current.iso8601}.csv", type: "text/csv"
      end
    end
  end

  private

  def business
    current_user.business
  end

  # Branches whose payroll cost the viewer may see (view_payroll + its scope).
  def payroll_branch_ids
    @payroll_branch_ids ||= Finance::PayrollCostAccess.new(current_user).branch_ids
  end

  # The payroll section's employee rows name each employee's pay, so they are
  # shown only for the entries the viewer may see (PayrollEntryPolicy scope:
  # view_payroll and its data scope); the branch subtotals and the section
  # total stay the report's cost figures, as in Branch Profitability. Returns
  # the entries left shown (for the payroll-entry view audit).
  def restrict_payroll_rows!(result)
    payroll = result.sections.find { |section| section.key == :payroll }
    return [] unless payroll

    ids     = payroll.groups.flat_map { |group| group.rows.map { |row| row[:payroll_entry_id] } }
    visible = policy_scope(PayrollEntry).where(id: ids).select(:id, :user_id, :payroll_period_id).to_a
    visible_ids = visible.to_set(&:id)
    payroll.groups.each { |group| group.rows = group.rows.select { |row| visible_ids.include?(row[:payroll_entry_id]) } }
    visible
  end

  # Reports are business-wide; gated by the dedicated report permission.
  def require_reports_access!
    return if current_user.can?(:view_expense_reports)

    redirect_to finance_root_path, alert: t("flash.not_authorized")
  end

  # Sets @dated so the view shows a date filter only for date-scoped reports
  # (recurring / custody-balance / outstanding don't call this).
  def date_range
    @dated = true
    @from  = parse_date(params[:from]) || 5.months.ago.to_date.beginning_of_month
    @to    = parse_date(params[:to])   || Date.current.end_of_month
    { from: @from, to: @to }
  end

  def parse_date(value)
    return nil if value.blank?

    Date.parse(value)
  rescue ArgumentError
    nil
  end

  def year
    (params[:year].presence || Date.current.year).to_i
  end

  def month
    (params[:month].presence || Date.current.month).to_i
  end

  # The immediately-preceding period of equal length to the current @from/@to
  # (set by date_range, which must be called first) — same "shift the window
  # back by its own span" shape already used by Finance::DashboardController.
  def previous_range
    previous_to   = @from - 1.day
    previous_from = previous_to - (@to - @from)
    { from: previous_from, to: previous_to }
  end

  # Row-level pct-of-total and period-over-period change, matched by label —
  # the same shape Finance::DashboardController already computes for
  # @top_categories. Pure arithmetic over totals the service already
  # returned; does not re-query or alter either table.
  def rows_with_change(current_rows, previous_rows)
    previous_by_label = previous_rows.index_by { |r| r[:label] }
    grand_total = current_rows.sum { |r| r[:total].to_f }

    current_rows.map do |row|
      prev = previous_by_label[row[:label]]&.dig(:total).to_f
      change = prev.zero? ? nil : ((row[:total].to_f - prev) / prev * 100)
      row.merge(pct: grand_total.zero? ? 0 : (row[:total].to_f / grand_total * 100), change: change)
    end
  end

  def load_breakdown_context(table, previous_table, branch_id: nil)
    @ranked_rows     = rows_with_change(table.rows, previous_table.rows)
    @previous_total  = previous_table.totals[:total]
    @overall_trend   = Finance::Reports::ExpenseTrend.new(business, from: @from, to: @to, branch_id: branch_id).call
  end

  # Resolves the filter bar once, then runs the current and comparison period
  # with the same branch. view_expense_reports is business-wide, so the branch
  # list is every branch of the viewer's business (inactive ones included —
  # they still carry historical expenses); a branch_id outside it is ignored.
  def filtered_expense_breakdown(group_by)
    @filters = Finance::Reports::ExpenseReportFilters.new(business, params).call
    @dated, @from, @to = true, @filters.from, @filters.to
    @report_branches = business.branches.order(:name).select(:id, :name, :active)

    branch_id = @filters.branch_id
    @breakdown_table = Finance::Reports::ExpenseSummary.new(business, group_by: group_by, branch_id: branch_id, **@filters.range).call
    previous = Finance::Reports::ExpenseSummary.new(business, group_by: group_by, branch_id: branch_id,
                                                    **@filters.previous_range).call
    load_breakdown_context(@breakdown_table, previous, branch_id: branch_id)
  end

  # Simple trailing N-period average over an already-computed numeric series
  # — display-only smoothing for the trend chart, not a new financial figure.
  def moving_average(values, window:)
    values.each_index.map do |i|
      slice = values[[ i - window + 1, 0 ].max..i]
      slice.sum / slice.size
    end
  end

  # Period-over-period change + margin, computed once here over the already-
  # fetched current/previous BranchProfitability totals — no new financial
  # formula, matches the exact shape rows_with_change already establishes for
  # the expense breakdown reports.
  def branch_profitability_rows(current_rows, previous_rows)
    previous_by_branch = previous_rows.index_by { |r| r[:branch] }

    current_rows.map do |row|
      prev = previous_by_branch[row[:branch]] || { revenue: 0, payroll: 0, inventory: 0, expenses: 0, net: 0 }
      change = %i[revenue expenses payroll inventory net].index_with do |key|
        next nil if row[key].nil? || prev[key].nil? # payroll / net not shown for this branch

        p = prev[key].to_f
        p.zero? ? nil : ((row[key].to_f - p) / p.abs * 100)
      end

      row.merge(
        margin: margin_pct(row[:net], row[:revenue]),
        previous: prev.merge(margin: margin_pct(prev[:net], prev[:revenue])),
        change: change
      )
    end
  end

  # nil when net profit is not shown (payroll outside the viewer's access).
  def margin_pct(net, revenue)
    return nil if net.nil?

    revenue.to_f.zero? ? 0 : (net.to_f / revenue.to_f * 100)
  end

  def render_report(table, template: :show)
    @table = table
    respond_to do |format|
      format.html { render template }
      format.csv  { send_csv(table, action_name) }
    end
  end

  def send_csv(table, key)
    send_data Finance::Reports::CsvExporter.new(table).to_csv,
              filename: "#{key}_#{Date.current.iso8601}.csv", type: "text/csv"
  end
end
