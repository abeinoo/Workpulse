module Attendance
  # Logs an accepted mobile punch as punch evidence (BiometricPunchLog, source
  # "mobile") — the same log device punches get — so Attendance::PunchAggregator
  # counts it like any other punch. Its direction and coordinates are kept in
  # raw_payload; the work date is the record's.
  module MobilePunchLog
    module_function

    def create!(record:, punch:, action:, business:)
      BiometricPunchLog.create!(
        business:          business,
        employee:          record.user,
        attendance_record: record,
        work_date:         record.work_date,
        punched_at:        punch.at,
        received_at:       punch.at,
        source:            "mobile",
        action:            action,
        raw_payload:       PunchAggregator.mobile_payload(punch, branch_id: record.branch_id).to_json
      )
    end
  end
end
