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

  def expenses_by_category
    range    = date_range
    table    = Finance::Reports::ExpenseSummary.new(business, group_by: :category, **range).call
    previous = Finance::Reports::ExpenseSummary.new(business, group_by: :category, **previous_range).call
    load_breakdown_context(table, previous)
    @drill_down_ids = business.expense_categories.pluck(:name, :id).to_h
    render_report(table, template: :expenses_by_category)
  end

  def expenses_by_type
    range    = date_range
    table    = Finance::Reports::ExpenseSummary.new(business, group_by: :type, **range).call
    previous = Finance::Reports::ExpenseSummary.new(business, group_by: :type, **previous_range).call
    load_breakdown_context(table, previous)
    @drill_down_ids = business.expense_types.pluck(:name, :id).to_h
    render_report(table, template: :expenses_by_type)
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
    @table          = Finance::Reports::BranchProfitability.new(business, year: @year, month: @month).call
    previous_month  = Date.new(@year, @month, 1) - 1.month
    @previous_table = Finance::Reports::BranchProfitability.new(business, year: previous_month.year, month: previous_month.month).call

    # Branch Profitability is a Sales-branch report (see Finance::Reports::
    # BranchProfitability) — narrowing the same assignable_branches collection
    # every other Finance page uses (not swapping it for a different query) so
    # a manually-submitted non-sales branch_id simply won't be found below and
    # falls through to the existing empty-selection handling, the same safe
    # behavior an inaccessible branch_id already gets.
    @accessible_branches = assignable_branches.where(branch_type: "sales")
    @branch_ids_by_name  = @accessible_branches.pluck(:name, :id).to_h
    @branch_rows         = branch_profitability_rows(@table.rows, @previous_table.rows)
    @ranked_branch_rows  = @branch_rows.sort_by { |r| -r[:net] }

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

  private

  def business
    current_user.business
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

  def load_breakdown_context(table, previous_table)
    @ranked_rows     = rows_with_change(table.rows, previous_table.rows)
    @previous_total  = previous_table.totals[:total]
    @overall_trend   = Finance::Reports::ExpenseTrend.new(business, from: @from, to: @to).call
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

  def margin_pct(net, revenue)
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
