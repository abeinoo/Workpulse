module Attendance
  # Applies manager edits to an attendance record and writes an immutable audit entry
  # for every field that changes. All changes happen in a single transaction.
  # Status is never user-editable — it is always re-derived from times after every save.
  class AdjustmentService
    include AuditLoggable
    Result = Struct.new(:success, :record, :error, keyword_init: true) do
      def success? = success
    end

    ADJUSTABLE_FIELDS = %w[check_in_at check_out_at].freeze

    def self.call(record:, adjusted_by:, params:)
      new(record: record, adjusted_by: adjusted_by, params: params).call
    end

    def initialize(record:, adjusted_by:, params:)
      @record      = record
      @adjusted_by = adjusted_by
      @params      = params.to_h.symbolize_keys
      @reason      = @params.delete(:reason)
    end

    def call
      return err("A reason is required for attendance adjustments") if @reason.blank?
      return err("No changes detected — all submitted values are unchanged") if nothing_changed?

      ActiveRecord::Base.transaction do
        build_audit_entries
        apply_field_changes
        recompute_derived_fields
        @record.updated_by = @adjusted_by
        @record.save!
        # Field-level entries saved automatically via autosave on has_many.
        emit_audit_log
      end

      Result.new(success: true, record: @record)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    private

    def build_audit_entries
      ADJUSTABLE_FIELDS.filter_map do |field|
        next unless @params.key?(field.to_sym)

        old_ser = serialize(field, @record.send(field))
        new_ser = serialize(field, @params[field.to_sym])
        next if old_ser == new_ser

        @record.attendance_adjustments.build(
          adjusted_by: @adjusted_by,
          field_name:  field,
          old_value:   old_ser,
          new_value:   new_ser,
          reason:      @reason
        )
      end
    end

    def apply_field_changes
      ADJUSTABLE_FIELDS.each do |field|
        next unless @params.key?(field.to_sym)
        value = @params[field.to_sym]
        value = parse_in_business_tz(value) if value.is_a?(String)
        @record.assign_attributes(field => value)
        # Track that this field was last set by a manual admin edit
        source_field = field == "check_in_at" ? :check_in_source : :check_out_source
        @record.assign_attributes(source_field => "admin_manual") if value.present?
      end
    end

    def recompute_derived_fields
      shift        = @record.shift_assignment&.shift
      branch       = @record.branch
      rule_profile = @record.shift_assignment&.rule_profile

      if @record.check_in_at && @record.check_out_at
        # late/early/worked are computed exactly as before (no grace profile applied)
        # so payroll-input minute values are unchanged. overtime_minutes is display-only.
        @record.worked_minutes      = ((@record.check_out_at - @record.check_in_at) / 60).to_i
        @record.late_minutes        = TimeCalculator.late_minutes(shift, @record.check_in_at, branch)
        @record.early_leave_minutes = TimeCalculator.early_leave_minutes(
          shift, @record.check_out_at, @record.worked_minutes, branch
        )
        @record.overtime_minutes    = TimeCalculator.overtime_minutes(
          shift, @record.worked_minutes,
          overtime_grace_minutes: business.overtime_grace_minutes.to_i,
          rule_profile:           rule_profile
        )
        @record.status = TimeCalculator.derive_status(
          shift:               shift,
          late_minutes:        @record.late_minutes,
          early_leave_minutes: @record.early_leave_minutes,
          overtime_minutes:    @record.overtime_minutes,
          completed:           true
        )
      else
        # Checkout absent or cleared — reset checkout-derived fields and revert status
        @record.worked_minutes      = nil
        @record.early_leave_minutes = 0
        @record.overtime_minutes    = 0
        @record.late_minutes        = TimeCalculator.late_minutes(shift, @record.check_in_at, branch)
        @record.status              = TimeCalculator.derive_status(
          shift:               shift,
          late_minutes:        @record.late_minutes,
          early_leave_minutes: 0,
          completed:           false
        )
      end
    end

    def business
      @record.branch&.business || @record.user.business
    end

    def nothing_changed?
      ADJUSTABLE_FIELDS.none? do |field|
        next false unless @params.key?(field.to_sym)
        serialize(field, @record.send(field)) != serialize(field, @params[field.to_sym])
      end
    end

    # Normalize field values to a stable UTC ISO8601 string for audit diff + change detection.
    # Both old (DB Time object) and new (String or Time param) are normalized to UTC so
    # comparison is timezone-independent. Bare datetime strings are assumed to be in the
    # business timezone; ISO8601 strings with an explicit offset are parsed respecting that offset.
    def serialize(field, value)
      return "" if value.nil?
      if %w[check_in_at check_out_at].include?(field)
        return "" if value.respond_to?(:blank?) && value.blank?
        t = value.is_a?(String) ? parse_in_business_tz(value) : value.to_time
        return "" if t.nil?
        t.utc.iso8601
      else
        value.to_s
      end
    rescue ArgumentError, TypeError
      value.to_s
    end

    # Parse a timestamp string in the business timezone so managers who type local times
    # (e.g. "09:30:00") get the correct UTC equivalent stored. ISO8601 strings with an
    # explicit offset ("2026-05-24T07:30:00Z", "…+02:00") have their offset respected.
    def parse_in_business_tz(value)
      return nil if value.blank?
      business.timezone_object.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def business
      @business ||= @record.branch&.business || @record.user.business
    end

    def emit_audit_log
      changed_fields = @record.attendance_adjustments.map do |adj|
        [adj.field_name, [adj.old_value, adj.new_value]]
      end.to_h

      log_audit(
        actor:     @adjusted_by,
        auditable: @record,
        action:    "edit_attendance",
        changes:   changed_fields,
        metadata:  { reason: @reason, status: @record.status }
      )
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
