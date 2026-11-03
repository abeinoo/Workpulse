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

      assignment = Shifts::AssignmentResolver.for(user: @user, branch: @branch)
      # Branchless employees may have no shift assignment — that's allowed.
      return err("No active shift found for today") if @branch && !assignment

      record = build_record(assignment)
      punch  = PunchAggregator::Punch.mobile(Time.current.floor(6), check_out: false,
                                             latitude: @latitude, longitude: @longitude)
      ActiveRecord::Base.transaction do
        aggregator = PunchAggregator.new(record, business: business)
        action     = aggregator.apply!(punch) || "recorded"
        record.save!
        aggregator.log_reconstructed_punches!
        MobilePunchLog.create!(record: record, punch: punch, action: action, business: business)
      end
      Result.new(success: true, record: record)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    rescue ActiveRecord::RecordNotUnique
      # Concurrent check-in: the unique index on (user_id, work_date) caught a race.
      # Treat identically to already_checked_in? returning true.
      err(I18n.t("api.attendance.already_checked_in"))
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

    # Check-in time, source, coordinates and every derived value come from
    # PunchAggregator (the mobile punch with the work date's other punches).
    def build_record(assignment)
      wd = BusinessDay.work_date_for(Time.current, context: business)
      AttendanceRecord.new(user: @user, branch: @branch, shift_assignment: assignment, date: wd, work_date: wd)
    end

    def business
      @branch&.business || @user.business
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
