module Attendance
  class CheckInService
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
      return err("Already checked in today") if already_checked_in?
      return err("You are not assigned to this branch") if @branch && !assigned_to_branch?
      return err("You are outside the allowed check-in area") unless location_valid?

      assignment = Shifts::AssignmentFinder.for(user: @user, branch: @branch)
      # Branchless employees may have no shift assignment — that's allowed.
      return err("No active shift found for today") if @branch && !assignment

      record = build_record(assignment)
      record.save ? Result.new(success: true, record: record)
                  : err(record.errors.full_messages.join(", "))
    end

    private

    def already_checked_in?
      AttendanceRecord.exists?(user: @user, work_date: BusinessDay.work_date_for(Time.current, context: business))
    end

    def assigned_to_branch?
      ShiftAssignment.current.exists?(user: @user, branch: @branch)
    end

    def location_valid?
      return true unless @branch
      GeolocationValidator.within_radius?(
        branch: @branch, latitude: @latitude, longitude: @longitude
      )
    end

    def build_record(assignment)
      now       = Time.current
      wd        = BusinessDay.work_date_for(now, context: business)
      late_mins = assignment ? TimeCalculator.late_minutes(assignment.shift, now, @branch) : 0
      status    = late_mins > 0 ? "late" : "incomplete"

      AttendanceRecord.new(
        user:               @user,
        branch:             @branch,
        shift_assignment:   assignment,
        date:               wd,
        work_date:          wd,
        check_in_at:        now,
        check_in_latitude:  @latitude,
        check_in_longitude: @longitude,
        late_minutes:       late_mins,
        status:             status
      )
    end

    def business
      @branch&.business || @user.business
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
