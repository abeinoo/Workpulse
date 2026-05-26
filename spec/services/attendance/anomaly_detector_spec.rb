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
    before { allow(BiometricPunchLog).to receive_message_chain(:where, :where, :pluck).and_return([]) }

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
      allow(BiometricPunchLog).to receive_message_chain(:where, :where, :pluck).and_return([])
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
      allow(BiometricPunchLog).to receive_message_chain(:where, :where, :pluck).and_return([])
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
      allow(BiometricPunchLog).to receive_message_chain(:where, :where, :pluck).and_return([])
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
      allow(BiometricPunchLog).to receive_message_chain(:where, :where, :pluck).and_return([])
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
      allow(BiometricPunchLog).to receive_message_chain(:where, :where, :pluck).and_return([])
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
      allow(BiometricPunchLog).to receive_message_chain(:where, :where, :pluck).and_return([])

      result = described_class.scan_users(users: [user, user2], from: from, to: to)
      expect(result).not_to be_empty
      expect(result.all? { |a| a.is_a?(described_class::Anomaly) }).to be true
    end
  end
end
