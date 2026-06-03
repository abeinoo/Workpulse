require "csv"

module Attendance
  # Parses a CSV of manual attendance records for preview before commit.
  #
  # Format (employee_code is the ONLY employee identifier — no name matching):
  #   employee_code,work_date,check_in,check_out,notes
  #   EMP001,2026-06-01,09:00,17:00,Reconstructed from sign-in sheet
  #   EMP002,2026-06-01,20:00,04:00,Overnight shift
  #   EMP003,2026-06-02,08:30,,Forgot to punch out
  #
  # check_in is required; check_out + notes are optional. Times are local "HH:MM"
  # combined with work_date in the business timezone at commit time.
  #
  # Each row is validated and tagged valid/invalid. Valid rows that fall inside a
  # finalized/paid (locked) payroll period are still importable but carry a
  # `locked` flag so the preview can warn that payroll will not be recalculated.
  class ManualRecordsCsvParser
    REQUIRED_HEADERS = %w[employee_code work_date check_in].freeze
    DATE_FORMATS     = [ "%Y-%m-%d", "%d/%m/%Y" ].freeze
    TIME_REGEX       = /\A([01]?\d|2[0-3]):([0-5]\d)\z/

    ParsedRow = Struct.new(
      :row_number, :employee_code, :user, :work_date, :check_in, :check_out,
      :notes, :locked, :duplicate, :valid, :errors,
      keyword_init: true
    ) do
      def user_id = user&.id
    end

    Result = Struct.new(
      :valid_rows, :invalid_rows, :total_rows, :header_error,
      keyword_init: true
    ) do
      def headers_valid? = header_error.nil?
      def valid_count    = valid_rows.size
      def invalid_count  = invalid_rows.size
      def locked_count   = valid_rows.count(&:locked)
    end

    # allowed_user_ids: the set of employee ids the importer may write to (scope).
    #                   When nil, any active business user is allowed.
    def initialize(csv_data:, business:, allowed_user_ids: nil)
      @csv_data         = csv_data.to_s
      @business         = business
      @allowed_user_ids = allowed_user_ids ? allowed_user_ids.map(&:to_i).to_set : nil
    end

    def call
      table = CSV.parse(
        @csv_data.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip,
        headers: true, skip_blanks: true, strip: true
      )
    rescue CSV::MalformedCSVError => e
      Result.new(valid_rows: [], invalid_rows: [], total_rows: 0,
                 header_error: "Invalid CSV: #{e.message}")
    else
      missing = missing_headers(table.headers)
      if missing.any?
        return Result.new(valid_rows: [], invalid_rows: [], total_rows: 0,
                          header_error: "Missing required columns: #{missing.join(', ')}")
      end

      users_by_code = build_user_index
      # Track (user_id, work_date) seen within this file to flag in-file duplicates.
      seen = {}

      parsed = table.each_with_index.map do |row, idx|
        parse_row(row, idx + 2, users_by_code, seen)
      end

      Result.new(
        valid_rows:   parsed.select(&:valid),
        invalid_rows: parsed.reject(&:valid),
        total_rows:   parsed.size,
        header_error: nil
      )
    end

    private

    def parse_row(row, row_num, users_by_code, seen)
      errs = []

      raw_code = row["employee_code"]&.strip
      user     = raw_code.present? ? users_by_code[raw_code.downcase] : nil
      if raw_code.blank?
        errs << "employee_code is required"
      elsif user.nil?
        errs << "Employee '#{raw_code}' not found"
      elsif @allowed_user_ids && !@allowed_user_ids.include?(user.id)
        errs << "Employee '#{raw_code}' is outside your permitted scope"
        user = nil
      end

      work_date = parse_date(row["work_date"])
      errs << "work_date '#{row['work_date']}' is not a valid date (use YYYY-MM-DD)" if work_date.nil?

      check_in = normalize_time(row["check_in"])
      if row["check_in"].blank?
        errs << "check_in is required"
      elsif check_in.nil?
        errs << "check_in '#{row['check_in']}' is not a valid time (use HH:MM)"
      end

      check_out = nil
      if row["check_out"].present?
        check_out = normalize_time(row["check_out"])
        errs << "check_out '#{row['check_out']}' is not a valid time (use HH:MM)" if check_out.nil?
      end

      duplicate = false
      if user && work_date
        key = [ user.id, work_date ]
        if seen[key]
          errs << "Duplicate row for this employee and date in the file"
        elsif AttendanceRecord.exists?(user_id: user.id, work_date: work_date)
          duplicate = true
          errs << "Employee already has an attendance record for #{work_date}"
        else
          seen[key] = row_num
        end
      end

      locked = (user && work_date) ? period_locked?(work_date) : false

      ParsedRow.new(
        row_number:    row_num,
        employee_code: raw_code,
        user:          user,
        work_date:     work_date,
        check_in:      check_in,
        check_out:     check_out,
        notes:         row["notes"]&.strip,
        locked:        locked,
        duplicate:     duplicate,
        valid:         errs.empty?,
        errors:        errs
      )
    end

    # employee_code → User. Active business users only; case-insensitive on code.
    def build_user_index
      @business.users.where(active: true)
               .select(:id, :first_name, :last_name, :employee_code, :business_id)
               .each_with_object({}) do |u, h|
                 h[u.employee_code.to_s.downcase] = u if u.employee_code.present?
               end
    end

    def period_locked?(work_date)
      PayrollPeriod.find_by(
        business:     @business,
        period_year:  work_date.year,
        period_month: work_date.month
      )&.locked? || false
    end

    def parse_date(str)
      str = str.to_s.strip
      return nil if str.blank?
      DATE_FORMATS.each do |fmt|
        parsed = Date.strptime(str, fmt) rescue next
        # strptime tolerates partial matches (e.g. "01-06-2026" under "%Y-%m-%d"),
        # so require an exact round-trip to reject ambiguous/garbage input.
        return parsed if parsed.strftime(fmt) == str
      end
      nil
    end

    # Returns "HH:MM" (zero-padded) or nil when invalid.
    def normalize_time(str)
      m = TIME_REGEX.match(str.to_s.strip)
      return nil unless m
      format("%02d:%02d", m[1].to_i, m[2].to_i)
    end

    def missing_headers(headers)
      normalized = Array(headers).map { |h| h&.strip&.downcase }
      REQUIRED_HEADERS.reject { |h| normalized.include?(h) }
    end
  end
end
