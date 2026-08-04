# Builds the "Employee Summary" .xlsx workbook from an already-built
# Performance::ReviewAnalytics instance. Exports every matching employee
# (ignores on-screen pagination) but respects the same filters/sort as the
# page — no separate recalculation.
module Performance
  module Exports
    class EmployeeSummaryWorkbook
      def initialize(analytics, sort: "average_rating", direction: "desc")
        @analytics = analytics
        @sort = sort
        @direction = direction
      end

      def call
        package = Axlsx::Package.new
        build_overview_sheet(package)
        build_employees_sheet(package)
        package.to_stream
      end

      private

      def build_overview_sheet(package)
        overview = @analytics.employee_summary_overview
        package.workbook.add_worksheet(name: "Overview") do |sheet|
          sheet.add_row [ "Employees Reviewed", overview.employees_reviewed ]
          sheet.add_row [ "Average Employee Rating", overview.average_employee_rating ]
          sheet.add_row [ "Highest Rated Employee", overview.highest_rated_employee_name, overview.highest_rated_employee_rating ]
          sheet.add_row [ "Lowest Rated Employee", overview.lowest_rated_employee_name, overview.lowest_rated_employee_rating ]
          sheet.add_row [ "Employees Below 3.5", overview.employees_below_threshold ]
          sheet.add_row [ "Employees Above 4.5", overview.employees_above_threshold ]
        end
      end

      def build_employees_sheet(package)
        rows = @analytics.employee_summary_rows(sort: @sort, direction: @direction, per_page: nil)
        package.workbook.add_worksheet(name: "Employee Summary") do |sheet|
          sheet.add_row [ "Employee", "Branch", "Department", "Reviews", "Average Rating",
                          "Highest Rating", "Lowest Rating", "Trend", "Last Review Date" ]
          rows.each do |row|
            sheet.add_row [
              row.employee_name, row.branch_name, row.department_name, row.reviews_count,
              row.average_rating, row.highest_rating, row.lowest_rating, row.trend&.capitalize,
              row.last_review_at&.to_date
            ]
          end
        end
      end
    end
  end
end
