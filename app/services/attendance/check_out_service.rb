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
      now    = Time.current.floor(6)
      record = record_to_check_out(now)
      return err("No active check-in found") unless record
      return err("You are outside the allowed check-out area") unless location_valid?

      punch = PunchAggregator::Punch.mobile(now, check_out: true, latitude: @latitude, longitude: @longitude)
      ActiveRecord::Base.transaction do
        record.lock!
        aggregator = PunchAggregator.new(record, business: business)
        action     = aggregator.apply!(punch) || "recorded"
        record.save!
        aggregator.log_reconstructed_punches!
        MobilePunchLog.create!(record: record, punch: punch, action: action, business: business)
      end
      Result.new(success: true, record: record)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    private

    def business
      @branch&.business || @user.business
    end

    # The current work date's record, open or closed (the check-out is the
    # latest punch of the work date, whatever its source: a device check-out
    # recorded earlier is replaced, a later one stays). Without one, the previous
    # work date's open record — an explicit check-out past the business-day
    # boundary of an overnight shift; never an older or a closed one.
    def record_to_check_out(now)
      # Memoized so location_valid? can reuse it without a second DB query.
      @record_to_check_out ||= begin
        work_date = BusinessDay.work_date_for(now, context: business)
        AttendanceRecord.find_by(user: @user, work_date: work_date) ||
          AttendanceRecord.find_by(user: @user, work_date: work_date - 1, check_out_at: nil)
      end
    end

    def location_valid?
      # Always validate against the branch stored on the checked-in record.
      # Using @branch (from params) would let an attacker supply a branch with no
      # geofence to bypass the enforcement that was active at check-in time.
      effective_branch = @record_to_check_out&.branch || @branch
      return true unless effective_branch
      GeolocationValidator.within_radius?(
        branch: effective_branch, latitude: @latitude, longitude: @longitude
      )
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
