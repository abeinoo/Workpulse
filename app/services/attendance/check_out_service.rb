module Attendance
  class CheckOutService
    Result = Struct.new(:success, :record, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(user:, branch:, latitude: nil, longitude: nil)
      new(user: user, branch: branch, latitude: latitude, longitude: longitude).call
    end

    def initialize(user:, branch:, latitude: nil, longitude: nil)
      @user      = user
      @branch    = branch
      @latitude  = latitude
      @longitude = longitude
    end

    def call
      record = open_record
      return err("No active check-in found") unless record
      return err("You are outside the allowed check-out area") unless location_valid?

      now              = Time.current
      worked_mins      = ((now - record.check_in_at) / 60).to_i
      shift            = record.shift_assignment&.shift
      rule_profile     = record.shift_assignment&.rule_profile
      early_leave_mins = shift ? TimeCalculator.early_leave_minutes(
        shift, now, worked_mins, @branch, rule_profile: rule_profile
      ) : 0
      overtime_mins    = TimeCalculator.overtime_minutes(
        shift, worked_mins,
        overtime_grace_minutes: business.overtime_grace_minutes.to_i,
        rule_profile:           rule_profile
      )

      record.assign_attributes(
        check_out_at:        now,
        check_out_source:    "mobile",
        check_out_latitude:  @latitude,
        check_out_longitude: @longitude,
        worked_minutes:      worked_mins,
        early_leave_minutes: early_leave_mins,
        overtime_minutes:    overtime_mins,
        status:              TimeCalculator.derive_status(
          shift:               shift,
          late_minutes:        record.late_minutes,
          early_leave_minutes: early_leave_mins,
          overtime_minutes:    overtime_mins,
          completed:           true
        )
      )

      record.save ? Result.new(success: true, record: record)
                  : err(record.errors.full_messages.join(", "))
    end

    private

    def business
      @branch&.business || @user.business
    end

    def open_record
      AttendanceRecord.where(user: @user, check_out_at: nil).order(check_in_at: :desc).first
    end

    def location_valid?
      return true unless @branch
      GeolocationValidator.within_radius?(
        branch: @branch, latitude: @latitude, longitude: @longitude
      )
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
