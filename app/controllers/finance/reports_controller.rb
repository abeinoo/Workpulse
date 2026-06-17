class Finance::ReportsController < Finance::BaseController
  before_action :require_reports_access!

  def index; end

  def expenses_by_branch   = render_report(Finance::Reports::ExpenseSummary.new(business, group_by: :branch, **date_range).call)
  def expenses_by_category = render_report(Finance::Reports::ExpenseSummary.new(business, group_by: :category, **date_range).call)
  def expenses_by_type     = render_report(Finance::Reports::ExpenseSummary.new(business, group_by: :type, **date_range).call)
  def expense_trend        = render_report(Finance::Reports::ExpenseTrend.new(business, **date_range).call)
  def shared_allocation    = render_report(Finance::Reports::SharedAllocation.new(business, **date_range).call)
  def recurring            = render_report(Finance::Reports::RecurringSummary.new(business).call)
  def custody_balances     = render_report(Finance::Reports::CustodyBalances.new(business).call)
  def custody_transactions = render_report(Finance::Reports::CustodyTransactions.new(business, **date_range).call)
  def negative_balances    = render_report(Finance::Reports::NegativeBalances.new(business).call)
  def approvals            = render_report(Finance::Reports::ApprovalReport.new(business, **date_range).call)

  def branch_profitability
    @year  = year
    @month = month
    @table = Finance::Reports::BranchProfitability.new(business, year: @year, month: @month).call
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

  def render_report(table)
    @table = table
    respond_to do |format|
      format.html { render :show }
      format.csv  { send_csv(table, action_name) }
    end
  end

  def send_csv(table, key)
    send_data Finance::Reports::CsvExporter.new(table).to_csv,
              filename: "#{key}_#{Date.current.iso8601}.csv", type: "text/csv"
  end
end
