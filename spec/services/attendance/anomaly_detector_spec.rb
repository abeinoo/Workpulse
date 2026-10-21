require "rails_helper"

RSpec.describe Attendance::AnomalyDetector do
  let(:business) { create(:business) }
  let(:user)     { create(:user, business: business) }
  let(:from)     { Date.current.beginning_of_month }
  let(:to)       { Date.current }

  def stub_records(attrs_list)
    attrs_list.map { |attrs| build_stubbed(:attendance_record, { user: user }.merge(attrs)) }
  end

  subject(:detector) { described_class.new(user: user, from: from, to: to) }

  context "with no records" do
    before { allow(AttendanceRecord).to receive_message_chain(:where, :where, :order, :to_a).and_return([]) }

    it "returns no anomalies" do
      expect(detector.detect).to be_empty
    end
  end

  describe "repeated lateness" do
    let(:late_records) do
      (0...3).map { |i|
        build_stubbed(:attendance_record,
          user:         user,
          work_date:    from + i.days,
          late_minutes: 45,
          status:       "late"
        )
      }
    end

    before do
      allow_any_instance_of(described_class).to receive(:records).and_return(late_records)
    end

    it "detects repeated_lateness warning" do
      expect(detector.detect.map(&:code)).to include(:repeated_lateness)
    end

    it "assigns warning severity" do
      anomaly = detector.detect.find { |a| a.code == :repeated_lateness }
      expect(anomaly.severity).to eq(:warning)
    end
  end

  describe "severe lateness" do
    let(:severe_records) do
      (0...3).map { |i|
        build_stubbed(:attendance_record,
          user:         user,
          work_date:    from + i.days,
          late_minutes: 60,
          status:       "late"
        )
      }
    end

    before do
      allow_any_instance_of(described_class).to receive(:records).and_return(severe_records)
    end

    it "detects severe_lateness as danger" do
      anomaly = detector.detect.find { |a| a.code == :severe_lateness }
      expect(anomaly).not_to be_nil
      expect(anomaly.severity).to eq(:danger)
    end
  end

  describe "suspicious punches" do
    let(:sus_records) do
      [ build_stubbed(:attendance_record,
          user:          user,
          work_date:     from,
          check_out_at:  from.to_time.change(hour: 9, min: 1),
          worked_minutes: 1,
          status:        "present"
        ) ]
    end

    before do
      allow_any_instance_of(described_class).to receive(:records).and_return(sus_records)
    end

    it "detects suspicious_punches" do
      expect(detector.detect.map(&:code)).to include(:suspicious_punches)
    end

    it "assigns danger severity" do
      anomaly = detector.detect.find { |a| a.code == :suspicious_punches }
      expect(anomaly.severity).to eq(:danger)
    end
  end

  describe "missed checkouts" do
    let(:incomplete_records) do
      (0...3).map { |i|
        build_stubbed(:attendance_record,
          user:      user,
          work_date: from + i.days,
          status:    "incomplete"
        )
      }
    end

    before do
      allow_any_instance_of(described_class).to receive(:records).and_return(incomplete_records)
    end

    it "detects missed_checkouts" do
      expect(detector.detect.map(&:code)).to include(:missed_checkouts)
    end
  end

  describe "sorting" do
    let(:mixed_records) do
      [
        build_stubbed(:attendance_record, user: user, work_date: from,      status: "present",
                      worked_minutes: 1, check_out_at: from.to_time.change(hour: 9, min: 1)),
        *( (1..3).map { |i| build_stubbed(:attendance_record, user: user, work_date: from + i.days,
                                          late_minutes: 60, status: "late") })
      ]
    end

    before do
      allow_any_instance_of(described_class).to receive(:records).and_return(mixed_records)
    end

    it "returns danger anomalies before warnings" do
      anomalies = detector.detect
      danger_idx  = anomalies.index { |a| a.severity == :danger }
      warning_idx = anomalies.index { |a| a.severity == :warning }
      next unless danger_idx && warning_idx
      expect(danger_idx).to be < warning_idx
    end
  end

  describe ".scan_users" do
    let(:user2) { create(:user, business: business) }

    let(:late_records_for_u1) do
      (0...3).map { |i|
        build_stubbed(:attendance_record,
          user: user, work_date: from + i.days,
          late_minutes: 45, status: "late"
        )
      }
    end

    it "returns anomalies for relevant users" do
      allow_any_instance_of(described_class).to receive(:records) do |instance|
        instance.instance_variable_get(:@user) == user ? late_records_for_u1 : []
      end

      result = described_class.scan_users(users: [user, user2], from: from, to: to)
      expect(result).not_to be_empty
      expect(result.all? { |a| a.is_a?(described_class::Anomaly) }).to be true
    end
  end

  # TD-T-2 — real punch logs and attendance records, no stubbed query: only
  # biometric-source logs with an evidence action make a "biometric day"; the day
  # is the calendar date of punched_at in the business time zone.
  describe "biometric mismatch" do
    around { |example| travel_to(Time.zone.parse("2026-07-15 09:00:00 UTC")) { example.run } } # 12:00 in Riyadh

    let(:business) { create(:business, timezone: "Asia/Riyadh") }
    let(:user)     { create(:user, business: business, first_name: "Sara", last_name: "Ali") }
    let(:days)     { [ Date.new(2026, 7, 2), Date.new(2026, 7, 5), Date.new(2026, 7, 9) ] }

    def local(day, hour, min = 0, sec = 0) = business.timezone_object.local(day.year, day.month, day.day, hour, min, sec)

    # Attendance with no shift assignment (as manual entry / CSV import write it).
    def unassigned_record(day)
      AttendanceRecord.create!(user: user, date: day, work_date: day, check_in_at: local(day, 9), status: "incomplete")
    end

    def device_log(day, action: "check_in", source: "biometric", at: local(day, 9))
      create(:biometric_punch_log, business: business, employee: user, action: action, source: source,
                                   punched_at: at, work_date: day)
    end

    def mismatches = described_class.new(user: user, from: from, to: to).detect.select { |a| a.code == :biometric_mismatch }

    it "reports one info anomaly for three qualifying days with unassigned attendance (format unchanged)" do
      days.each { |day| unassigned_record(day) && device_log(day) }

      expect(mismatches.size).to eq(1)
      expect(mismatches.first).to have_attributes(
        user: user, severity: :info, count: 3, dates: days,
        message: I18n.t("attendance.anomalies.biometric_mismatch", count: 3, name: "Sara Ali")
      )
      expect(described_class::REPEAT_THRESHOLD).to eq(3)
    end

    it "reports nothing for only two qualifying days" do
      days.first(2).each { |day| unassigned_record(day) && device_log(day) }
      unassigned_record(days.last)

      expect(mismatches).to be_empty
    end

    BiometricPunchLog::BIOMETRIC_MISMATCH_EVIDENCE_ACTIONS.each do |action|
      it "counts a biometric #{action} log as evidence" do
        days.each { |day| unassigned_record(day) && device_log(day, action: action) }

        expect(mismatches.map(&:count)).to eq([ 3 ])
      end
    end

    %w[rejected_not_allowed rejected_stale_timestamp error].each do |action|
      it "does not count a biometric #{action} log" do
        days.each { |day| unassigned_record(day) && device_log(day, action: action) }

        expect(mismatches).to be_empty
      end
    end

    BiometricPunchLog::ACTIONS.each do |action|
      it "does not count a mobile-source #{action} log" do
        days.each { |day| unassigned_record(day) && device_log(day, action: action, source: "mobile") }

        expect(mismatches).to be_empty
      end
    end

    it "decides per day: a day whose only logs are excluded does not count toward the threshold" do
      days.each(&method(:unassigned_record))
      days.first(2).each { |day| device_log(day) }
      device_log(days.last, action: "rejected_stale_timestamp")
      device_log(days.last, action: "check_in", source: "mobile")

      expect(mismatches).to be_empty
    end

    it "ignores logs outside the requested range" do
      days.each(&method(:unassigned_record))
      device_log(from - 1.day, at: local(from - 1.day, 23, 59, 59)) # the evening before the range (Riyadh)
      device_log(to + 1.day)
      device_log(days.first)
      device_log(days.second)

      expect(mismatches).to be_empty
    end

    it "uses the calendar date of punched_at in the business time zone, not the log's work_date" do
      days.each(&method(:unassigned_record))
      days.first(2).each { |day| device_log(day) }
      device_log(days.last - 1.day, at: local(days.last, 0, 30)) # 00:30 local on the third day, work_date the day before

      expect(mismatches.map(&:dates)).to eq([ days ])
    end

    it "does not treat a record with a shift assignment as unassigned attendance" do
      days.first(2).each(&method(:unassigned_record))
      assigned = create(:attendance_record, business: business, user: user, date: days.last, work_date: days.last,
                                            check_in_at: local(days.last, 9))
      days.each { |day| device_log(day) }

      expect(assigned.shift_assignment_id).not_to be_nil
      expect(mismatches).to be_empty
    end
  end
end
