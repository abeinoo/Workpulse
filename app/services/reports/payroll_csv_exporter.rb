require "csv"

module Reports
  class PayrollCsvExporter
    def self.call(period:, business: nil)
      new(period: period, business: business).call
    end

    def initialize(period:, business: nil)
      @period   = period
      @business = business || period.business
      @currency = @business&.currency || "SAR"
    end

    def call
      summary = PayrollSummary.call(period: @period)

      CSV.generate(headers: true) do |csv|
        csv << ["Currency: #{@currency}"]
        csv << headers
        summary[:entries].each { |row| csv << row_values(row) }
        csv << []
        csv << totals_row(summary[:totals])
      end
    end

    private

    def headers
      [
        "Employee ID", "Full Name", "Salary Type",
        "Base Salary (#{@currency})", "Working Days", "Days Worked",
        "Total Deductions (#{@currency})", "Total Overtime (#{@currency})",
        "Total Bonuses (#{@currency})", "Paid During Period (#{@currency})",
        "Advances Deducted (#{@currency})", "Obligations Deducted (#{@currency})",
        "Final Payable (#{@currency})", "Status"
      ]
    end

    def row_values(row)
      [
        row[:user_id], row[:full_name], row[:salary_type],
        row[:base_salary], row[:working_days], row[:days_worked],
        row[:total_deductions], row[:total_overtime], row[:total_bonuses],
        row[:already_paid_total],
        row[:advances_deducted], row[:obligations_deducted], row[:net_salary], row[:status]
      ]
    end

    def totals_row(totals)
      [
        "", "TOTALS", "",
        totals[:base_salary], "", "",
        totals[:deductions], totals[:overtime], totals[:bonuses],
        totals[:already_paid_total],
        totals[:advances_deducted], totals[:obligations_deducted], totals[:net_salary], ""
      ]
    end
  end
end
