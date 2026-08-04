# Builds the "Review Analytics" .xlsx workbook straight from an already-built
# Performance::ReviewAnalytics instance — every number here was already
# computed in SQL by the service; this class only formats it into sheets.
# Never re-queries or recalculates anything itself.
module Performance
  module Exports
    class ReviewsWorkbook
      def initialize(analytics)
        @analytics = analytics
      end

      def call
        package = Axlsx::Package.new
        build_summary_sheet(package)
        build_department_sheet(package) if @analytics.multiple_departments?
        build_branch_sheet(package) if @analytics.multiple_branches?
        build_trend_sheet(package)
        build_rankings_sheet(package)
        package.to_stream
      end

      private

      def build_summary_sheet(package)
        package.workbook.add_worksheet(name: "Summary") do |sheet|
          sheet.add_row [ "Total Reviews", @analytics.total_reviews ]
          sheet.add_row [ "Average Rating", @analytics.average_rating ]
          sheet.add_row [ "Highest Rating", @analytics.highest_rating ]
          sheet.add_row [ "Lowest Rating", @analytics.lowest_rating ]
          sheet.add_row []
          sheet.add_row [ "Stars", "Count", "Percentage" ]
          @analytics.star_distribution_with_percentage.sort_by { |star, _| -star }.each do |star, data|
            sheet.add_row [ "#{star} Star", data[:count], "#{data[:percentage]}%" ]
          end

          if (comparison = @analytics.previous_period_comparison)
            sheet.add_row []
            sheet.add_row [ "Previous Period" ]
            sheet.add_row [ "Previous Average Rating", comparison.previous_average_rating ]
            sheet.add_row [ "Rating Delta", comparison.rating_delta ]
            sheet.add_row [ "Previous Review Count", comparison.previous_review_count ]
            sheet.add_row [ "Review Count Delta", comparison.review_count_delta ]
          end
        end
      end

      def build_department_sheet(package)
        package.workbook.add_worksheet(name: "Departments") do |sheet|
          sheet.add_row [ "Department", "Review Count", "Average Rating" ]
          @analytics.department_summaries.each do |row|
            sheet.add_row [ row.department_name, row.review_count, row.average_rating ]
          end
        end
      end

      def build_branch_sheet(package)
        package.workbook.add_worksheet(name: "Branches") do |sheet|
          sheet.add_row [ "Branch", "Review Count", "Average Rating" ]
          @analytics.branch_summaries.each do |row|
            sheet.add_row [ row.branch_name || "Unassigned", row.review_count, row.average_rating ]
          end
        end
      end

      def build_trend_sheet(package)
        package.workbook.add_worksheet(name: "Trend") do |sheet|
          sheet.add_row [ "Period", "Average Rating", "Review Count" ]
          @analytics.rating_trend.each do |point|
            sheet.add_row [ point.label, point.average, point.count ]
          end
        end
      end

      def build_rankings_sheet(package)
        package.workbook.add_worksheet(name: "Top & Bottom Employees") do |sheet|
          sheet.add_row [ "Top Employees" ]
          sheet.add_row [ "Employee", "Average Rating", "Review Count" ]
          @analytics.top_employees.each { |r| sheet.add_row [ r.employee_name, r.average_rating, r.review_count ] }
          sheet.add_row []
          sheet.add_row [ "Bottom Employees" ]
          sheet.add_row [ "Employee", "Average Rating", "Review Count" ]
          @analytics.bottom_employees.each { |r| sheet.add_row [ r.employee_name, r.average_rating, r.review_count ] }
        end
      end
    end
  end
end
