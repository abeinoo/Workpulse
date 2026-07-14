class Laundry::Reports::CostSummaryController < Laundry::BaseController
  before_action :require_reports_access!

  def index
    @from, @to = date_range
    @summary = Laundry::LaundryCostSummaryReport.new(current_user.business, from: @from, to: @to).call

    respond_to do |format|
      format.html
      format.csv { send_data csv_export, filename: "laundry_cost_summary_#{Date.current.iso8601}.csv", type: "text/csv" }
    end
  end

  private

  # This report exposes payroll cost — unlike the branch consumption report,
  # it is never branch-scoped down to a partial view; it's business-wide only.
  def require_reports_access!
    return if current_user.can?(:view_laundry_cost_reports)

    redirect_to laundry_root_path, alert: t("flash.not_authorized")
  end

  def date_range
    from = parse_date(params[:from]) || BusinessDay.current(context: current_user.business).beginning_of_month
    to   = parse_date(params[:to])   || BusinessDay.current(context: current_user.business).end_of_month
    [ from, to ]
  end

  def parse_date(value)
    return nil if value.blank?

    Date.parse(value)
  rescue ArgumentError
    nil
  end

  def csv_export
    columns = [
      Finance::Reports::Column.new(key: :category, label: t("laundry.reports.cost_summary.csv.category")),
      Finance::Reports::Column.new(key: :amount, label: t("laundry.reports.cost_summary.csv.amount"), money: true),
      Finance::Reports::Column.new(key: :period, label: t("laundry.reports.cost_summary.csv.period"))
    ]
    period = "#{@from.iso8601} - #{@to.iso8601}"
    rows = [
      { category: t("laundry.reports.cost_summary.payroll_cost"), amount: @summary.payroll_cost, period: period },
      { category: t("laundry.reports.cost_summary.direct_expenses"), amount: @summary.direct_expenses, period: period },
      { category: t("laundry.reports.cost_summary.material_cost"), amount: @summary.material_cost, period: period },
      { category: t("laundry.reports.cost_summary.total_actual_cost"), amount: @summary.actual_operating_cost, period: period },
      { category: t("laundry.reports.cost_summary.standard_branch_cost"), amount: @summary.consumption&.total_cost, period: period },
      { category: t("laundry.reports.cost_summary.coverage_variance"), amount: @summary.coverage_variance, period: period }
    ]
    table = Finance::Reports::Table.new(title: t("laundry.reports.cost_summary.title"), columns: columns,
                                        rows: rows, totals: nil)
    Finance::Reports::CsvExporter.new(table).to_csv
  end
end
