require "csv"

module Reports
  # Builds the bank-transfer payment file for a finalized payroll period.
  #
  # The net payable amount is taken straight from PayrollEntry#net_salary — the
  # single source of truth that already reflects base salary, overtime overrides,
  # advances, penalties, bonuses and every approved adjustment. This exporter
  # never recomputes payroll; it only selects, validates and formats.
  #
  # Pass `entries:` to supply a pre-scoped relation (e.g. from policy_scope) so
  # the file only contains employees the caller is authorised to see.
  #
  # Eligibility (a row is excluded entirely when it fails either rule):
  #   - net salary must be > 0
  #   - the entry must be "active" (disputed entries are held back from payment)
  #
  # A blank national ID does NOT exclude the row — it is still exported, flagged
  # in the Issues column so finance can chase the missing identity number.
  class BankTransferCsvExporter
    Row = Struct.new(:employee_code, :full_name, :national_id, :net_salary, :issues, keyword_init: true)

    MISSING_NATIONAL_ID = "Missing National ID".freeze

    HEADERS = ["Employee Code", "Employee Name", "National ID", "Net Salary", "Issues"].freeze

    def self.call(period:, entries: nil)
      new(period: period, entries: entries).to_csv
    end

    def initialize(period:, entries: nil)
      @period  = period
      @entries = entries
    end

    # Eligible, validated rows — memoised so the controller can render the
    # summary banner and the CSV from a single pass over the data.
    def rows
      @rows ||= eligible_entries.map { |entry| build_row(entry) }
    end

    # Banner figures shown before the download is triggered.
    def summary
      {
        total_employees:     rows.size,
        total_amount:        rows.sum(&:net_salary).round(2),
        missing_national_id: rows.count { |row| row.issues.present? }
      }
    end

    def to_csv
      CSV.generate do |csv|
        csv << HEADERS
        rows.each do |row|
          csv << [row.employee_code, row.full_name, row.national_id, row.net_salary, row.issues]
        end
      end
    end

    def filename
      format("payroll_bank_transfer_%04d_%02d.csv", @period.period_year, @period.period_month)
    end

    # The entries the CSV contains (for the payroll-entry view audit).
    def eligible_entries
      @eligible_entries ||= (@entries || @period.payroll_entries).includes(:user)
                            .reject { |entry| entry.disputed? || entry.net_salary.to_f <= 0 }
                            .sort_by { |entry| entry.user.employee_code.to_i }
    end

    private

    def build_row(entry)
      national_id = entry.user.identity_card_number.presence

      Row.new(
        employee_code: entry.user.employee_code,
        full_name:     entry.user.full_name,
        national_id:   national_id,
        net_salary:    entry.net_salary.to_f,
        issues:        national_id.blank? ? MISSING_NATIONAL_ID : nil
      )
    end
  end
end
