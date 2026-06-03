module Attendance
  # Creates many manual attendance records in a single all-or-nothing transaction.
  #
  # Used by both the bulk grid (manual rows) and the CSV import confirm step. Every
  # row is built + validated first; only if ALL rows are valid are they persisted —
  # a single bad row rejects the whole batch with per-row errors (mirrors
  # Adjustments::BulkCreateService). Each saved record goes through the same
  # ManualEntryService.build_record / finalize! path as single entry, so audit +
  # created_by are identical regardless of how the record was created.
  #
  # After commit, any *draft* payroll period whose month was touched is regenerated
  # (Payroll::DraftRegenerator). Finalized/paid periods are never recalculated; rows
  # landing there are still saved for attendance history and counted in locked_count.
  class BulkManualEntryService
    RowError = Struct.new(:index, :employee, :messages, keyword_init: true)

    Result = Struct.new(:success, :count, :locked_count, :row_errors, keyword_init: true) do
      def success? = success
      def failed?  = !success
    end

    EMPTY = Result.new(success: false, count: 0, locked_count: 0, row_errors: []).freeze

    # rows: array of hashes with :user_id, :work_date, :check_in, :check_out, :notes
    # allowed_user_ids: scope guard — only these employee ids may be written.
    def initialize(rows:, business:, created_by:, allowed_user_ids:, source: "bulk_manual")
      @rows             = Array(rows).map { |r| symbolize(r) }.reject { |r| row_blank?(r) }
      @business         = business
      @created_by       = created_by
      @allowed_user_ids = allowed_user_ids.map(&:to_i).to_set
      @source           = source
    end

    def call
      return EMPTY if @rows.empty?

      users   = preload_users
      built   = []          # [ [index, record, notes, work_date] ]
      errors  = []
      seen    = {}          # in-batch (user_id, work_date) dedupe

      @rows.each_with_index do |row, idx|
        user = users[row[:user_id].to_i]
        unless user
          errors << RowError.new(index: idx, employee: row[:user_id], messages: [ scope_error ])
          next
        end

        begin
          record = ManualEntryService.build_record(
            employee: user, actor: @created_by,
            work_date: row[:work_date], check_in: row[:check_in], check_out: row[:check_out]
          )
        rescue ArgumentError, TypeError
          errors << RowError.new(index: idx, employee: user.full_name,
                                 messages: [ I18n.t("attendance.manual.errors.invalid_time") ])
          next
        end

        key = [ user.id, record.work_date ]
        if seen[key]
          errors << RowError.new(index: idx, employee: user.full_name,
                                 messages: [ I18n.t("attendance.manual.errors.duplicate_in_batch") ])
          next
        end
        if AttendanceRecord.exists?(user_id: user.id, work_date: record.work_date)
          errors << RowError.new(index: idx, employee: user.full_name,
                                 messages: [ I18n.t("attendance.manual.errors.duplicate") ])
          next
        end
        unless record.valid?
          errors << RowError.new(index: idx, employee: user.full_name,
                                 messages: record.errors.full_messages)
          next
        end

        seen[key] = idx
        built << [ idx, record, row[:notes] ]
      end

      return Result.new(success: false, count: 0, locked_count: 0, row_errors: errors) if errors.any?

      persist!(built)
    end

    private

    def persist!(built)
      finalizer       = ManualEntryService.new(created_by: @created_by)
      affected_months = []

      ActiveRecord::Base.transaction do
        built.each { |(_idx, record, notes)| finalizer.finalize!(record, notes: notes) }
      end

      built.each { |(_idx, record, _notes)| affected_months << [ record.work_date.year, record.work_date.month ] }
      locked = built.count { |(_idx, record, _notes)| period_locked?(record.work_date) }

      Payroll::DraftRegenerator.call(
        business: @business, months: affected_months.uniq, triggered_by: @created_by
      )

      Result.new(success: true, count: built.size, locked_count: locked, row_errors: [])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success: false, count: 0, locked_count: 0,
                 row_errors: [ RowError.new(index: nil, employee: nil, messages: [ e.message ]) ])
    end

    def preload_users
      @business.users
               .where(id: @rows.map { |r| r[:user_id].to_i }.uniq, active: true)
               .where(id: @allowed_user_ids.to_a)
               .index_by(&:id)
    end

    def period_locked?(work_date)
      PayrollPeriod.find_by(
        business: @business, period_year: work_date.year, period_month: work_date.month
      )&.locked? || false
    end

    def scope_error
      I18n.t("attendance.manual.errors.employee_required")
    end

    def symbolize(row)
      row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h.symbolize_keys : row.to_h.symbolize_keys
    end

    def row_blank?(row)
      row[:user_id].blank? && row[:check_in].blank? && row[:work_date].blank?
    end
  end
end
