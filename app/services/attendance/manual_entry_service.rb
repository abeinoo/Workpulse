module Attendance
  # Creates an attendance record by hand for an authorized user (manage_attendance).
  #
  # Times are entered as local "HH:MM" against a chosen work_date and combined in
  # the business timezone. An overnight check-out (time <= check-in time) rolls to
  # the next calendar day so cross-midnight shifts are handled. Derived fields
  # (late/early/worked/status) are recomputed via RecordRecomputer, the active
  # shift assignment + branch are linked when present, and the creation is audited
  # (created_by + AuditLog + a "manual_entry" attendance_adjustment carrying notes).
  #
  # Reused by BulkManualEntryService: `build_record` (pure, unsaved) and
  # `finalize!` (save + audit) are the shared building blocks so single and bulk
  # creation produce identical records and audit trails.
  class ManualEntryService
    include AuditLoggable

    Result = Struct.new(:success, :record, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(employee:, created_by:, work_date:, check_in:, check_out: nil, notes: nil)
      new(created_by: created_by, employee: employee)
        .create_single(work_date: work_date, check_in: check_in, check_out: check_out, notes: notes)
    end

    # ── Shared builders (used by single + bulk) ───────────────────────────────

    # Build an unsaved, fully-derived AttendanceRecord from local inputs.
    # Raises ArgumentError/TypeError on unparseable date/time — callers rescue.
    def self.build_record(employee:, actor:, work_date:, check_in:, check_out: nil)
      wd = work_date.is_a?(Date) ? work_date : Date.parse(work_date.to_s)
      tz = employee.business.timezone_object

      check_in_at  = combine(tz, wd, check_in)
      check_out_at = nil
      if check_out.to_s.strip.present?
        check_out_at = combine(tz, wd, check_out)
        # Overnight: a check-out at or before the check-in clock time belongs to
        # the following calendar day (e.g. in 20:00 → out 04:00).
        check_out_at += 1.day if check_out_at <= check_in_at
      end

      assignment = ShiftAssignment.active_on(wd).find_by(user_id: employee.id)

      record = AttendanceRecord.new(
        user:             employee,
        branch:           assignment&.branch,
        shift_assignment: assignment,
        date:             wd,
        work_date:        wd,
        check_in_at:      check_in_at,
        check_in_source:  "admin_manual",
        check_out_at:     check_out_at,
        check_out_source: (check_out_at ? "admin_manual" : nil),
        created_by:       actor,
        updated_by:       actor
      )

      Attendance::RecordRecomputer.recompute!(record)
      record
    end

    # Combine a Date with an "HH:MM" string in the given timezone.
    def self.combine(tz, date, time_str)
      hours, minutes = time_str.to_s.split(":").first(2).map(&:to_i)
      tz.local(date.year, date.month, date.day, hours, minutes, 0)
    end

    def initialize(created_by:, employee: nil)
      @created_by = created_by
      @employee   = employee
    end

    # Persist a built record + its audit trail. MUST run inside a transaction.
    def finalize!(record, notes:)
      record.save!
      record.attendance_adjustments.create!(
        adjusted_by: @created_by,
        field_name:  "manual_entry",
        old_value:   nil,
        new_value:   manual_entry_summary(record),
        reason:      notes.to_s.strip.presence || I18n.t("attendance.manual.default_reason")
      )
      log_audit(
        actor:     @created_by,
        auditable: record,
        action:    "create_manual_attendance",
        changes:   {
          check_in_at:  [ nil, record.check_in_at&.iso8601 ],
          check_out_at: [ nil, record.check_out_at&.iso8601 ]
        },
        metadata:  { notes: notes, status: record.status, work_date: record.work_date.to_s }
      )
      record
    end

    # ── Single-entry path (validation + own transaction) ──────────────────────

    def create_single(work_date:, check_in:, check_out: nil, notes: nil)
      return err(I18n.t("attendance.manual.errors.employee_required")) if @employee.nil?

      wd = parse_date(work_date)
      return err(I18n.t("attendance.manual.errors.date_required"))     if wd.nil?
      return err(I18n.t("attendance.manual.errors.check_in_required")) if check_in.to_s.strip.blank?

      if AttendanceRecord.exists?(user_id: @employee.id, work_date: wd)
        return err(I18n.t("attendance.manual.errors.duplicate"))
      end

      record = self.class.build_record(
        employee: @employee, actor: @created_by,
        work_date: wd, check_in: check_in, check_out: check_out
      )

      ActiveRecord::Base.transaction { finalize!(record, notes: notes) }

      Result.new(success: true, record: record)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    rescue ArgumentError, TypeError
      err(I18n.t("attendance.manual.errors.invalid_time"))
    end

    private

    def parse_date(value)
      return value if value.is_a?(Date)
      str = value.to_s.strip
      return nil if str.blank?
      Date.parse(str)
    rescue ArgumentError, TypeError
      nil
    end

    def manual_entry_summary(record)
      out = record.check_out_at ? record.check_out_at.iso8601 : "—"
      "in=#{record.check_in_at.iso8601} out=#{out}"
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
