require "csv"

module Reports
  class PayrollCsvExporter
    HEADERS = [
      "Employee ID", "Full Name", "Salary Type",
      "Base Salary", "Working Days", "Days Worked",
      "Total Deductions", "Total Overtime", "Total Bonuses",
      "Advances Deducted", "Net Salary", "Status"
    ].freeze

    def self.call(period:)
      new(period: period).call
    end

    def initialize(period:)
      @period = period
    end

    def call
      summary = PayrollSummary.call(period: @period)

      CSV.generate(headers: true) do |csv|
        csv << HEADERS
        summary[:entries].each { |row| csv << row_values(row) }
        csv << []
        csv << totals_row(summary[:totals])
      end
    end

    private

    def row_values(row)
      [
        row[:user_id], row[:full_name], row[:salary_type],
        row[:base_salary], row[:working_days], row[:days_worked],
        row[:total_deductions], row[:total_overtime], row[:total_bonuses],
        row[:advances_deducted], row[:net_salary], row[:status]
      ]
    end

    def totals_row(totals)
      [
        "", "TOTALS", "",
        totals[:base_salary], "", "",
        totals[:deductions], totals[:overtime], totals[:bonuses],
        totals[:advances_deducted], totals[:net_salary], ""
      ]
    end
  end
end
