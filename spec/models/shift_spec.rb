require "rails_helper"

RSpec.describe Shift, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:business) }
    it { is_expected.to have_many(:penalty_rules).dependent(:destroy) }
    it { is_expected.to have_many(:shift_assignments).dependent(:restrict_with_error) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:shift_type) }

    describe "name uniqueness per business" do
      it "rejects duplicate name within same business" do
        business = create(:business)
        create(:shift, name: "Morning", business: business)
        duplicate = build(:shift, name: "Morning", business: business)
        expect(duplicate).not_to be_valid
      end

      it "allows the same name in a different business" do
        create(:shift, name: "Morning")
        other = build(:shift, name: "Morning")
        expect(other).to be_valid
      end
    end

    context "fixed_time shifts" do
      subject { build(:shift, :fixed_time) }

      it { is_expected.to validate_presence_of(:start_time) }
      it { is_expected.to validate_presence_of(:end_time) }

      it "is invalid without start_time" do
        expect(build(:shift, :fixed_time, start_time: nil)).not_to be_valid
      end

      it "is invalid without end_time" do
        expect(build(:shift, :fixed_time, end_time: nil)).not_to be_valid
      end
    end

    context "hour_based shifts" do
      subject { build(:shift, :hour_based) }

      it "is invalid without required_hours" do
        expect(build(:shift, :hour_based, required_hours: nil)).not_to be_valid
      end

      it "is invalid when required_hours is zero" do
        expect(build(:shift, :hour_based, required_hours: 0)).not_to be_valid
      end

      it "does not require start_time or end_time" do
        expect(build(:shift, :hour_based)).to be_valid
      end
    end

    describe "overtime_rate_multiplier" do
      it "must be >= 1 when set" do
        expect(build(:shift, overtime_rate_multiplier: 0.5)).not_to be_valid
      end

      it "allows nil" do
        expect(build(:shift, overtime_rate_multiplier: nil)).to be_valid
      end

      it "allows values >= 1" do
        expect(build(:shift, overtime_rate_multiplier: 1.5)).to be_valid
      end
    end
  end

  describe "#overnight?" do
    it "returns true when end_time is before start_time" do
      expect(build(:shift, :overnight).overnight?).to be true
    end

    it "returns false for a daytime shift" do
      expect(build(:shift, :fixed_time).overnight?).to be false
    end

    it "returns false for an hour_based shift" do
      expect(build(:shift, :hour_based).overnight?).to be false
    end

    it "returns false when start_time == end_time" do
      shift = build(:shift, :fixed_time,
                    start_time: Time.zone.parse("09:00"),
                    end_time:   Time.zone.parse("09:00"))
      expect(shift.overnight?).to be false
    end
  end

  describe "#timed?" do
    it "returns true for a fixed_time shift with both clock times" do
      expect(build(:shift, :fixed_time).timed?).to be true
    end

    it "returns true for an overnight shift" do
      expect(build(:shift, :overnight).timed?).to be true
    end

    it "returns false for an hour_based (flexible) shift" do
      expect(build(:shift, :hour_based).timed?).to be false
    end

    it "returns false when start_time is nil" do
      shift = build(:shift, shift_type: :fixed_time, start_time: nil, end_time: Time.zone.parse("17:00"))
      expect(shift.timed?).to be false
    end

    it "returns false when end_time is nil" do
      shift = build(:shift, shift_type: :fixed_time, start_time: Time.zone.parse("09:00"), end_time: nil)
      expect(shift.timed?).to be false
    end

    it "returns false when both times are nil (legacy record)" do
      shift = build(:shift, shift_type: :fixed_time, start_time: nil, end_time: nil)
      expect(shift.timed?).to be false
    end
  end

  describe "#duration_minutes" do
    context "fixed_time shift with 9-to-5 hours" do
      it "returns 480 minutes" do
        shift = build(:shift, :fixed_time,
                      start_time: Time.zone.parse("09:00"),
                      end_time:   Time.zone.parse("17:00"))
        expect(shift.duration_minutes).to eq(480)
      end
    end

    context "overnight shift (13:00 → 01:00)" do
      it "returns 720 minutes (12 hours)" do
        expect(build(:shift, :overnight).duration_minutes).to eq(720)
      end
    end

    context "hour_based shift requiring 8 hours" do
      it "returns 480 minutes" do
        shift = build(:shift, :hour_based, required_hours: 8.0)
        expect(shift.duration_minutes).to eq(480)
      end
    end

    context "when start_time or end_time is nil (fixed_time)" do
      it "returns nil" do
        shift = build(:shift, shift_type: :fixed_time, start_time: nil, end_time: nil)
        expect(shift.duration_minutes).to be_nil
      end
    end
  end
end
