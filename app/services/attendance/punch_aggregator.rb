module Attendance
  # Derives a work date's effective check-in and check-out from ALL its valid
  # punches — mobile and device alike, with equal priority — so the same set of
  # punches always yields the same record, whatever order they arrived in.
  #
  # Evidence (the punch set of one employee's work date, i.e. business day —
  # BusinessDay.work_date_for, the attribution every punch already gets; punches
  # of another work date are never read):
  #   - every BiometricPunchLog of the employee, business and work date whose
  #     action is in EVIDENCE_ACTIONS — device punches and, since this change,
  #     mobile punches (source "mobile"; direction and coordinates in raw_payload);
  #   - rejected_spam logs only when linked to the record: duplicates are linked
  #     since this change, so they count; the unlinked ones logged before it
  #     (3,318 in production on 2026-11-02 — mostly repeat scans seconds after a
  #     check-out) never took part in a calculation and stay out, so a new punch
  #     cannot move a historical day by them;
  #   - the record's own check-in / check-out when they come from a punch that has
  #     no log (mobile punches recorded before mobile punches were logged);
  #   - the punch being processed.
  #
  # Selection (a pure function of the set):
  #   - check-in  = the earliest punch;
  #   - check-out = the latest punch, when the day has a departure: the latest
  #     punch is at least MIN_CHECK_OUT_GAP after the earliest, or an explicit
  #     mobile check-out exists.
  #     BUSINESS ASSUMPTION (agreed 2026-11-03, not a fact about punch direction):
  #     device punches carry no direction, so whether a later device punch is a
  #     departure or another entry scan cannot be known. WorkPulse assumes no
  #     shift is shorter than MIN_CHECK_OUT_GAP: a device-only day whose punches
  #     all fall within it of the first has no check-out — the missing check-out
  #     stays visible for a manager to correct instead of becoming a
  #     minutes-long "complete" day with an early-leave penalty. A genuine
  #     shorter day needs a mobile check-out or a manager correction. Every such
  #     punch is still logged ("recorded") and kept as evidence. Revisit if
  #     devices start sending a reliable direction.
  #   - ties on the same instant are broken by source, then direction, so the
  #     choice is deterministic.
  #
  # Manual values are pinned: a check-in / check-out set by a person (source
  # admin_manual — manual edits, manual entries, approved punch corrections —
  # import or api) or edited through Attendance::AdjustmentService (an
  # AttendanceAdjustment for the field, which also covers a cleared field) is
  # never replaced by a punch; the punch is still logged as evidence.
  #
  # Location: a record's coordinates belong to the punch that is effective for
  # that field — a mobile punch's coordinates, none for a device punch (devices
  # report none and none are invented). A mobile punch that leaves the record
  # keeps its coordinates in its punch log; an unlogged one (legacy) is logged
  # first (action "recorded", raw_payload "reconstructed_from_record": true).
  #
  # #apply! mutates the record in memory (times, sources, coordinates and, via
  # Attendance::DerivedFields, every derived value); the caller saves it, then
  # calls #log_reconstructed_punches! and logs the processed punch.
  class PunchAggregator
    MIN_CHECK_OUT_GAP = 1.hour

    # Punches that passed every validity check. rejected_spam is a duplicate
    # label, not a validity verdict: its moment is a real punch and counts —
    # when linked to the record (see above).
    EVIDENCE_ACTIONS = %w[check_in check_in_updated check_out recorded].freeze

    PUNCH_RECORD_SOURCES = [ nil, "mobile", "biometric_device" ].freeze
    LOG_TO_RECORD_SOURCE = { "biometric" => "biometric_device", "mobile" => "mobile" }.freeze
    RECORD_TO_LOG_SOURCE = LOG_TO_RECORD_SOURCE.invert.freeze

    # source: the record-side source ("mobile" / "biometric_device");
    # check_out: true only for an explicit mobile check-out.
    Punch = Data.define(:at, :source, :check_out, :latitude, :longitude) do
      def self.device(at)                              = new(at: at, source: "biometric_device", check_out: false, latitude: nil, longitude: nil)
      def self.mobile(at, check_out:, latitude:, longitude:) = new(at: at, source: "mobile", check_out: check_out, latitude: latitude, longitude: longitude)

      def sort_key = [ at, source.to_s, check_out ? 1 : 0, latitude.to_s, longitude.to_s ]
    end

    def self.mobile_payload(punch, branch_id:)
      { direction: punch.check_out ? "check_out" : "check_in",
        latitude: punch.latitude, longitude: punch.longitude, branch_id: branch_id }
    end

    def initialize(record, business:, assignment: record.shift_assignment, branch: record.branch)
      @record     = record
      @business   = business
      @assignment = assignment
      @branch     = branch
      @reconstructed = []
    end

    # Returns the punch's own effect: "check_in" (first check-in of the record),
    # "check_in_updated", "check_out", or nil when it is not the effective
    # check-in / check-out it changed.
    def apply!(punch)
      evidence = (logged_punches + unlogged_record_punches + [ punch ]).uniq.sort_by(&:sort_key)
      first    = evidence.first
      last     = evidence.last
      departed = last.at - first.at >= MIN_CHECK_OUT_GAP || evidence.any? { |p| p.check_out && p.at > first.at }

      in_punch  = pinned?(:check_in) ? nil : first
      out_punch = pinned?(:check_out) || !departed ? nil : last
      effective_in = in_punch&.at || @record.check_in_at
      # A punch never removes a check-out, nor sets one not after the check-in.
      out_punch = nil if out_punch && effective_in && out_punch.at <= effective_in

      first_check_in = @record.check_in_at.nil?
      changed_in  = in_punch  && assign(:check_in,  in_punch)
      changed_out = out_punch && assign(:check_out, out_punch)

      DerivedFields.apply!(@record, assignment: @assignment, branch: @branch, mobile_grace: true)

      if changed_in && in_punch == punch
        first_check_in ? "check_in" : "check_in_updated"
      elsif changed_out && out_punch == punch
        "check_out"
      end
    end

    # Logs the unlogged punches #apply! moved off the record, so none is lost.
    # Call after the record is saved.
    def log_reconstructed_punches!
      @reconstructed.each do |field, punch|
        BiometricPunchLog.create!(
          business:          @business,
          employee:          @record.user,
          attendance_record: @record,
          work_date:         @record.work_date,
          punched_at:        punch.at,
          received_at:       Time.current,
          source:            RECORD_TO_LOG_SOURCE.fetch(punch.source),
          action:            "recorded",
          raw_payload:       { reconstructed_from_record: true, field: field,
                               direction: punch.check_out ? "check_out" : "check_in",
                               latitude: punch.latitude, longitude: punch.longitude }.to_json
        )
      end
    end

    private

    def logged_punches
      @logged_punches ||= begin
        logs = BiometricPunchLog.where(business: @business, employee: @record.user, work_date: @record.work_date)
        logs = logs.where(action: EVIDENCE_ACTIONS)
                   .or(logs.where(action: "rejected_spam", attendance_record_id: @record.id || 0))
        logs.pluck(:punched_at, :source, :raw_payload)
      end.map { |at, source, payload| logged_punch(at, source, payload) }
    end

    def logged_punch(at, source, payload)
      return Punch.device(at) unless source == "mobile"

      data = JSON.parse(payload.to_s) rescue {}
      Punch.mobile(at, check_out: data["direction"] == "check_out",
                       latitude: data["latitude"], longitude: data["longitude"])
    end

    # The record's punch-sourced times with no matching log (legacy mobile).
    def unlogged_record_punches
      unlogged_by_field.values
    end

    def unlogged_by_field
      @unlogged_by_field ||= %i[check_in check_out].filter_map do |field|
        punch = record_punch(field)
        next unless punch
        next if logged_punches.any? { |p| p.at == punch.at && p.source == punch.source }

        [ field, punch ]
      end.to_h
    end

    def record_punch(field)
      at     = @record.public_send(:"#{field}_at")
      source = @record.public_send(:"#{field}_source")
      return unless at && PUNCH_RECORD_SOURCES.include?(source) && !pinned?(field)

      Punch.new(at: at, source: source, check_out: field == :check_out && source == "mobile",
                latitude: @record.public_send(:"#{field}_latitude"), longitude: @record.public_send(:"#{field}_longitude"))
    end

    def pinned?(field)
      @pinned ||= {}
      @pinned.fetch(field) do
        source = @record.public_send(:"#{field}_source")
        @pinned[field] = (@record.public_send(:"#{field}_at").present? && !PUNCH_RECORD_SOURCES.include?(source)) ||
                         (@record.persisted? && @record.attendance_adjustments.exists?(field_name: "#{field}_at"))
      end
    end

    # Puts the punch on the field; true when anything changed. An unlogged punch
    # it displaces is queued for #log_reconstructed_punches!.
    def assign(field, punch)
      current = @record.public_send(:"#{field}_at")
      return false if current == punch.at && @record.public_send(:"#{field}_source") == punch.source

      displaced = unlogged_by_field[field]
      @reconstructed << [ field, displaced ] if displaced && displaced != punch && RECORD_TO_LOG_SOURCE.key?(displaced.source)

      @record.assign_attributes(
        "#{field}_at":        punch.at,
        "#{field}_source":    punch.source,
        "#{field}_latitude":  punch.latitude,
        "#{field}_longitude": punch.longitude
      )
      true
    end
  end
end
