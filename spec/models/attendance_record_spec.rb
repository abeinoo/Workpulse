require "rails_helper"

RSpec.describe AttendanceRecord, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:branch).optional }
    it { is_expected.to belong_to(:shift_assignment).optional }
    it { is_expected.to have_many(:attendance_adjustments).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:attendance_record) }

    it { is_expected.to validate_presence_of(:user) }
    it { is_expected.to validate_presence_of(:date) }
    it { is_expected.to validate_presence_of(:work_date) }
    it { is_expected.to validate_presence_of(:check_in_at) }

    describe "work_date uniqueness per user" do
      it "prevents two records for the same user on the same work_date" do
        existing = create(:attendance_record)
        duplicate = build(:attendance_record, user: existing.user, work_date: existing.work_date,
                          date: existing.date + 1,
                          branch: existing.branch, shift_assignment: existing.shift_assignment)
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:work_date]).to be_present
      end

      it "allows the same work_date for different users" do
        create(:attendance_record, work_date: Date.current)
        record2 = build(:attendance_record, work_date: Date.current)
        expect(record2).to be_valid
      end
    end

    describe "numeric fields" do
      it "rejects negative late_minutes" do
        expect(build(:attendance_record, late_minutes: -1)).not_to be_valid
      end

      it "rejects negative early_leave_minutes" do
        expect(build(:attendance_record, early_leave_minutes: -1)).not_to be_valid
      end

      it "rejects negative worked_minutes" do
        expect(build(:attendance_record, worked_minutes: -1)).not_to be_valid
      end

      it "allows nil worked_minutes (not yet checked out)" do
        expect(build(:attendance_record, worked_minutes: nil)).to be_valid
      end
    end
  end

  describe "#overnight?" do
    let(:business) { create(:business) }
    let(:branch)   { create(:branch, business: business) }
    let(:overnight_shift) { create(:shift, :overnight, business: business) }

    it "returns true when checkout is on the next calendar day" do
      record = create(
        :attendance_record,
        branch:         branch,
        shift:          overnight_shift,
        work_date:      Date.current,
        date:           Date.current,
        check_in_at:    Time.current.change(hour: 13),
        check_out_at:   1.day.from_now.change(hour: 1),
        worked_minutes: 720,
        status:         :present
      )
      expect(record.overnight?).to be true
    end

    it "returns false when checkout is on the same calendar day" do
      record = build(:attendance_record, :checked_out)
      expect(record.overnight?).to be false
    end

    it "returns false when not yet checked out" do
      record = build(:attendance_record)
      expect(record.overnight?).to be false
    end

    it "uses business timezone for midnight boundary (Riyadh UTC+3)" do
      # work_date = May 15; checkout at 21:30 UTC = 00:30 May 16 in Riyadh → overnight
      riyadh_biz = create(:business, timezone: "Asia/Riyadh")
      riyadh_branch = create(:branch, business: riyadh_biz)
      record = build(
        :attendance_record,
        branch:      riyadh_branch,
        work_date:   Date.new(2026, 5, 15),
        check_in_at: Time.utc(2026, 5, 15, 8, 0, 0),
        check_out_at: Time.utc(2026, 5, 15, 21, 30, 0)
      )
      expect(record.overnight?).to be true
    end

    it "is false when checkout looks like next UTC day but is same business-TZ day (Cairo UTC+2)" do
      # checkout at 22:30 UTC = 00:30 next day in Cairo → overnight
      # this is a separate confirmation that Cairo (UTC+2) also triggers correctly
      cairo_biz    = create(:business, timezone: "Africa/Cairo")
      cairo_branch = create(:branch, business: cairo_biz)
      record = build(
        :attendance_record,
        branch:      cairo_branch,
        work_date:   Date.new(2026, 5, 15),
        check_in_at: Time.utc(2026, 5, 15, 8, 0, 0),
        check_out_at: Time.utc(2026, 5, 15, 22, 30, 0)
      )
      expect(record.overnight?).to be true
    end
  end

  describe "#checked_out?" do
    it "returns true when check_out_at is present" do
      record = build(:attendance_record, :checked_out)
      expect(record.checked_out?).to be true
    end

    it "returns false when check_out_at is nil" do
      record = build(:attendance_record)
      expect(record.checked_out?).to be false
    end
  end

  describe "#total_penalty_minutes" do
    it "sums late and early leave minutes" do
      record = build(:attendance_record, late_minutes: 30, early_leave_minutes: 45)
      expect(record.total_penalty_minutes).to eq(75)
    end

    it "returns 0 when both fields are zero" do
      record = build(:attendance_record, late_minutes: 0, early_leave_minutes: 0)
      expect(record.total_penalty_minutes).to eq(0)
    end
  end

  describe "scopes" do
    let(:business) { create(:business) }
    let(:branch)   { create(:branch, business: business) }
    let(:user1)    { create(:user, business: business) }
    let(:user2)    { create(:user, business: business) }
    let!(:today_record)     { create(:attendance_record, date: Date.current, work_date: Date.current, user: user1, branch: branch) }
    let!(:yesterday_record) { create(:attendance_record, :for_yesterday, user: user2, branch: branch) }

    describe ".for_date" do
      it "returns records on the given date" do
        expect(AttendanceRecord.for_date(Date.current)).to include(today_record)
        expect(AttendanceRecord.for_date(Date.current)).not_to include(yesterday_record)
      end
    end

    describe ".for_period" do
      it "returns records within the work_date range" do
        period = AttendanceRecord.for_period(Date.yesterday, Date.current)
        expect(period).to include(today_record, yesterday_record)
      end

      it "excludes records outside the range" do
        old = create(:attendance_record, date: 10.days.ago.to_date, work_date: 10.days.ago.to_date)
        period = AttendanceRecord.for_period(Date.yesterday, Date.current)
        expect(period).not_to include(old)
      end

      it "groups overnight checkout by work_date not checkout date" do
        overnight_record = create(:attendance_record,
                                  user:             user1,
                                  branch:           branch,
                                  shift_assignment: today_record.shift_assignment,
                                  work_date:        Date.yesterday,
                                  date:             Date.yesterday,
                                  check_in_at:      1.day.ago.change(hour: 13),
                                  check_out_at:     Time.current.change(hour: 1),
                                  worked_minutes:   720,
                                  status:           :present)
        period = AttendanceRecord.for_period(Date.yesterday, Date.yesterday)
        expect(period).to include(overnight_record)
        outside = AttendanceRecord.for_period(Date.current, Date.current)
        expect(outside).not_to include(overnight_record)
      end
    end

    describe ".for_business" do
      let!(:other_record) { create(:attendance_record) }

      it "returns only records for the given business" do
        result = AttendanceRecord.for_business(business)
        expect(result).to include(today_record, yesterday_record)
        expect(result).not_to include(other_record)
      end
    end

    describe ".active / .deleted" do
      before { today_record.update!(deleted_at: Time.current, deleted_by: user2) }

      it ".active excludes soft-deleted records" do
        expect(AttendanceRecord.active).not_to include(today_record)
        expect(AttendanceRecord.active).to include(yesterday_record)
      end

      it ".deleted returns only soft-deleted records" do
        expect(AttendanceRecord.deleted).to include(today_record)
        expect(AttendanceRecord.deleted).not_to include(yesterday_record)
      end
    end
  end

  describe "#deleted?" do
    it "returns true when deleted_at is present" do
      record = build(:attendance_record, deleted_at: Time.current)
      expect(record.deleted?).to be true
    end

    it "returns false when deleted_at is nil" do
      record = build(:attendance_record, deleted_at: nil)
      expect(record.deleted?).to be false
    end
  end
end
