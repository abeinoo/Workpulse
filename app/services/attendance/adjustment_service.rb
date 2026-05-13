module Attendance
  # Applies manager edits to an attendance record and writes an immutable audit entry
  # for every field that changes. All changes happen in a single transaction.
  class AdjustmentService
    Result = Struct.new(:success, :record, :error, keyword_init: true) do
      def success? = success
    end

    ADJUSTABLE_FIELDS = %w[check_in_at check_out_at status].freeze

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
        @record.save!
        # Adjustments are saved automatically via autosave on the has_many association
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
        @record.assign_attributes(field => @params[field.to_sym])
      end
    end

    def recompute_derived_fields
      return unless @record.check_in_at && @record.check_out_at

      shift = @record.shift_assignment.shift

      @record.worked_minutes      = ((@record.check_out_at - @record.check_in_at) / 60).to_i
      @record.late_minutes        = TimeCalculator.late_minutes(shift, @record.check_in_at, @record.branch)
      @record.early_leave_minutes = TimeCalculator.early_leave_minutes(
        shift, @record.check_out_at, @record.worked_minutes, @record.branch
      )

      # Only derive status automatically when the editor didn't explicitly set it
      unless @params.key?(:status)
        @record.status = TimeCalculator.derive_status(@record.late_minutes, @record.early_leave_minutes)
      end
    end

    def nothing_changed?
      ADJUSTABLE_FIELDS.none? do |field|
        next false unless @params.key?(field.to_sym)
        serialize(field, @record.send(field)) != serialize(field, @params[field.to_sym])
      end
    end

    # Normalize field values to a stable string for audit diff + change detection.
    # Datetime fields → ISO8601 (via Time.zone.parse so strings and Time objects match).
    # Other fields (enum strings like status) → plain to_s.
    def serialize(field, value)
      return "" if value.nil?
      if %w[check_in_at check_out_at].include?(field)
        t = value.respond_to?(:to_time) ? value.to_time : Time.zone.parse(value.to_s)
        t.iso8601
      else
        value.to_s
      end
    rescue ArgumentError, TypeError
      value.to_s
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
