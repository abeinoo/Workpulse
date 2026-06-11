module Attendance
  # Reclassifies existing AttendanceRecords under the new status engine for DISPLAY
  # only. It reads the already-stored late_minutes / early_leave_minutes /
  # worked_minutes and writes ONLY `status` and `overtime_minutes` via
  # update_columns. It never recomputes or mutates the payroll-input minute fields,
  # so payroll calculations are unaffected.
  #
  # Use dry_run: true to preview the impact without writing.
  class StatusBackfill
    Result = Struct.new(
      :scanned, :changed, :to_overtime, :to_late_early_leave,
      :by_new_status, :errors,
      keyword_init: true
    ) do
      def success? = errors.empty?
    end

    def self.call(scope: AttendanceRecord.all, dry_run: false)
      new(scope: scope, dry_run: dry_run).call
    end

    def initialize(scope:, dry_run:)
      @scope   = scope
      @dry_run = dry_run
    end

    def call
      scanned = 0
      changed = 0
      to_ot   = 0
      to_lel  = 0
      by_status = Hash.new(0)
      errors    = []

      # `absent` is a no-record/scheduling outcome the punch-derived engine never
      # produces — leave those rows untouched.
      @scope
        .where.not(status: "absent")
        .includes(user: :business, branch: :business,
                  shift_assignment: [ :rule_profile, { shift: :penalty_rules } ])
        .find_each do |record|
        scanned += 1
        begin
          new_status, new_ot = compute(record)

          next if new_status == record.status && new_ot == record.overtime_minutes.to_i

          changed += 1
          by_status[new_status] += 1
          to_ot  += 1 if new_status == "overtime"         && record.status != "overtime"
          to_lel += 1 if new_status == "late_early_leave" && record.status != "late_early_leave"

          # update_columns writes ONLY these two columns — late/early/worked and
          # updated_at are left exactly as they were.
          record.update_columns(status: new_status, overtime_minutes: new_ot) unless @dry_run
        rescue => e
          errors << { record_id: record.id, error: "#{e.class}: #{e.message}" }
          Rails.logger.warn("[StatusBackfill] record=#{record.id}: #{e.class}: #{e.message}")
        end
      end

      Result.new(
        scanned:             scanned,
        changed:             changed,
        to_overtime:         to_ot,
        to_late_early_leave: to_lel,
        by_new_status:       by_status,
        errors:              errors
      )
    end

    private

    # Returns [status, overtime_minutes] derived from STORED minute values.
    def compute(record)
      shift = record.shift_assignment&.shift

      if record.check_out_at.present?
        grace = (record.branch&.business || record.user.business).overtime_grace_minutes.to_i
        ot = TimeCalculator.overtime_minutes(
          shift, record.worked_minutes,
          overtime_grace_minutes: grace,
          rule_profile:           record.shift_assignment&.rule_profile
        ).to_i
        status = TimeCalculator.derive_status(
          shift:               shift,
          late_minutes:        record.late_minutes,
          early_leave_minutes: record.early_leave_minutes,
          overtime_minutes:    ot,
          completed:           true
        )
        [ status, ot ]
      else
        status = TimeCalculator.derive_status(
          shift:               shift,
          late_minutes:        record.late_minutes,
          early_leave_minutes: 0,
          completed:           false
        )
        [ status, 0 ]
      end
    end
  end
end
