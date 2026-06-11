module Attendance
  # Recomputes the canonical derived fields for AttendanceRecord rows using the
  # same TimeCalculator pipeline as PunchService, CheckInService, CheckOutService,
  # and AdjustmentService.
  #
  # Fields recomputed:
  #   - late_minutes           (TimeCalculator.late_minutes)
  #   - early_leave_minutes    (TimeCalculator.early_leave_minutes)
  #   - worked_minutes         (integer seconds / 60, truncated)
  #   - status                 (TimeCalculator.derive_status)
  #
  # Two entry points:
  #
  #   RecordRecomputer.recompute!(record)
  #     Mutates the record's fields in memory. Does NOT save.
  #     Returns true if any field changed, false if already correct.
  #     Used by CsvImporter (record is new/dirty and will be saved by the caller).
  #
  #   RecordRecomputer.call(scope:)
  #     Batch-processes an AttendanceRecord relation, saving only the rows
  #     that change. Safe to run multiple times — already-correct rows are
  #     untouched. Returns a Result with per-category counts.
  class RecordRecomputer
    Result = Struct.new(
      :updated, :skipped, :failed, :errors, :affected_periods,
      keyword_init: true
    ) do
      def success? = failed.zero?
    end

    # ── Single-record entry point ─────────────────────────────────────────────

    # Recomputes derived fields for one AttendanceRecord in memory.
    # Caller is responsible for saving.
    # Returns true when at least one field was changed.
    def self.recompute!(record)
      new.recompute!(record)
    end

    # ── Batch entry point ─────────────────────────────────────────────────────

    # Batch-recomputes and saves every record in +scope+.
    # scope: an ActiveRecord::Relation on AttendanceRecord.
    # Returns a Result.
    def self.call(scope:)
      new.call(scope: scope)
    end

    # ── Instance methods ──────────────────────────────────────────────────────

    # Mutates record in place; returns true iff any field changed.
    def recompute!(record)
      shift        = record.shift   # shift_assignment&.shift
      branch       = record.branch
      rule_profile = record.shift_assignment&.rule_profile
      ot_grace     = (branch&.business || record.user.business).overtime_grace_minutes.to_i

      new_late = shift ? TimeCalculator.late_minutes(
        shift, record.check_in_at, branch, rule_profile: rule_profile
      ) : 0

      if record.check_in_at.present? && record.check_out_at.present?
        worked_mins = ((record.check_out_at - record.check_in_at) / 60).to_i

        # early_leave_minutes: fixed-time shifts require branch for TZ lookup;
        # hour-based shifts only need worked vs required hours.
        new_early = if shift && (shift.hour_based? || branch.present?)
          TimeCalculator.early_leave_minutes(
            shift, record.check_out_at, worked_mins, branch, rule_profile: rule_profile
          )
        else
          0
        end

        new_overtime = TimeCalculator.overtime_minutes(
          shift, worked_mins, overtime_grace_minutes: ot_grace, rule_profile: rule_profile
        )

        new_status = TimeCalculator.derive_status(
          shift:               shift,
          late_minutes:        new_late,
          early_leave_minutes: new_early,
          overtime_minutes:    new_overtime,
          completed:           true
        )

        changed = record.late_minutes        != new_late     ||
                  record.early_leave_minutes != new_early    ||
                  record.overtime_minutes    != new_overtime ||
                  record.worked_minutes      != worked_mins  ||
                  record.status              != new_status

        record.late_minutes        = new_late
        record.early_leave_minutes = new_early
        record.overtime_minutes    = new_overtime
        record.worked_minutes      = worked_mins
        record.status              = new_status
      else
        # Open record (no checkout yet)
        new_early    = 0
        new_overtime = 0
        new_status   = TimeCalculator.derive_status(
          shift:               shift,
          late_minutes:        new_late,
          early_leave_minutes: 0,
          completed:           false
        )

        changed = record.late_minutes        != new_late        ||
                  record.early_leave_minutes != new_early       ||
                  record.overtime_minutes    != new_overtime    ||
                  record.worked_minutes.present?                 ||   # must be nil without checkout
                  record.status              != new_status

        record.late_minutes        = new_late
        record.early_leave_minutes = new_early
        record.overtime_minutes    = new_overtime
        record.worked_minutes      = nil
        record.status              = new_status
      end

      changed
    end

    # Batch-saves all records in scope that need recomputation.
    # Eager-loads associations to avoid N+1.
    def call(scope:)
      updated          = 0
      skipped          = 0
      failed           = 0
      errors           = []
      affected_periods = []   # [[business_id, year, month], ...]

      scope
        .includes(user: :business, branch: :business, shift_assignment: [ :rule_profile, { shift: :penalty_rules } ])
        .find_each do |record|
        begin
          if recompute!(record)
            record.save!
            updated += 1
            affected_periods << [
              record.user.business_id,
              record.work_date.year,
              record.work_date.month
            ]
          else
            skipped += 1
          end
        rescue => e
          failed += 1
          errors << { record_id: record.id, error: "#{e.class}: #{e.message}" }
          Rails.logger.warn(
            "[RecordRecomputer] Failed record=#{record.id}: #{e.class}: #{e.message}"
          )
        end
      end

      Result.new(
        updated:          updated,
        skipped:          skipped,
        failed:           failed,
        errors:           errors,
        affected_periods: affected_periods.uniq
      )
    end
  end
end
