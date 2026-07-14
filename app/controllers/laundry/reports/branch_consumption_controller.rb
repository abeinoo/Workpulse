class Laundry::Reports::BranchConsumptionController < Laundry::BaseController
  before_action :require_reports_access!

  def index
    @from, @to = date_range
    @branches     = assignable_branches
    @towel_types  = laundry_towel_types

    branch_id     = scoped_branch_id
    towel_type_id = params[:towel_type_id].presence
    @towel_type_filter = @towel_types.find { |t| t.id.to_s == towel_type_id.to_s } if towel_type_id

    @report = Laundry::BranchTowelConsumptionReport.new(
      current_user.business, from: @from, to: @to, branch_id: branch_id, towel_type_id: towel_type_id
    ).call

    respond_to do |format|
      format.html
      format.csv { send_data csv_export, filename: "branch_towel_consumption_#{Date.current.iso8601}.csv", type: "text/csv" }
    end
  end

  private

  def require_reports_access!
    return if current_user.can?(:view_laundry_consumption_reports)

    redirect_to laundry_root_path, alert: t("flash.not_authorized")
  end

  # Branch managers (scoped, not business-wide) are restricted to their own
  # branch's rows regardless of the branch_id param they pass.
  def scoped_branch_id
    return params[:branch_id].presence unless params[:branch_id].present?
    return params[:branch_id] if current_user.owner?

    scope_type = current_user.scope_for(:view_laundry_consumption_reports)
    return params[:branch_id] if scope_type.to_s == "business"

    allowed = BranchScope.new(current_user).for_scope(scope_type)
    allowed.include?(params[:branch_id].to_i) ? params[:branch_id] : allowed.first
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
      Finance::Reports::Column.new(key: :branch, label: t("laundry.reports.branch_consumption.csv.branch")),
      Finance::Reports::Column.new(key: :towel_type, label: t("laundry.common.towel_type")),
      Finance::Reports::Column.new(key: :confirmed_quantity, label: t("laundry.reports.branch_consumption.csv.confirmed_quantity")),
      Finance::Reports::Column.new(key: :standard_cost, label: t("laundry.reports.branch_consumption.csv.standard_cost"), money: true),
      Finance::Reports::Column.new(key: :total_cost, label: t("laundry.reports.branch_consumption.csv.total_cost"), money: true),
      Finance::Reports::Column.new(key: :period, label: t("laundry.reports.branch_consumption.csv.period"))
    ]
    period = "#{@from.iso8601} - #{@to.iso8601}"
    rows = @report.rows.flat_map do |row|
      row.events.map do |e|
        { branch: row.branch.name, towel_type: e.towel_type.name, confirmed_quantity: e.confirmed_quantity,
          standard_cost: e.rate, total_cost: e.line_total, period: period }
      end
    end
    table = Finance::Reports::Table.new(title: t("laundry.reports.branch_consumption.title"), columns: columns,
                                        rows: rows, totals: nil)
    Finance::Reports::CsvExporter.new(table).to_csv
  end
end
