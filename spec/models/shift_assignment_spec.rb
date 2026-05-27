require "rails_helper"

RSpec.describe ShiftAssignment, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:shift) }
    it { is_expected.to belong_to(:branch).optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:effective_from) }

    describe "effective_to_after_effective_from" do
      it "is invalid when effective_to equals effective_from" do
        date = Date.current
        assignment = build(:shift_assignment, effective_from: date, effective_to: date)
        expect(assignment).not_to be_valid
        expect(assignment.errors[:effective_to]).to be_present
      end

      it "is invalid when effective_to is before effective_from" do
        assignment = build(:shift_assignment,
                           effective_from: Date.current,
                           effective_to:   Date.current - 1.day)
        expect(assignment).not_to be_valid
      end

      it "is valid when effective_to is after effective_from" do
        assignment = build(:shift_assignment,
                           effective_from: Date.current,
                           effective_to:   Date.current + 30.days)
        expect(assignment).to be_valid
      end

      it "is valid when effective_to is nil (open-ended)" do
        assignment = build(:shift_assignment, effective_to: nil)
        expect(assignment).to be_valid
      end
    end

    describe "no_overlapping_shift_time" do
      let(:business)  { create(:business) }
      let(:user)      { create(:user, business: business) }
      let(:branch_a)  { create(:branch, business: business) }
      let(:branch_b)  { create(:branch, business: business) }
      # Morning: 09:00–17:00
      let(:morning)   { create(:shift, :fixed_time, business: business, name: "Morning",
                               start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00")) }
      # Afternoon: 13:00–21:00 (overlaps morning 13:00–17:00)
      let(:afternoon) { create(:shift, :fixed_time, business: business, name: "Afternoon",
                               start_time: Time.zone.parse("13:00"), end_time: Time.zone.parse("21:00")) }
      # Evening: 18:00–02:00 overnight (no overlap with morning)
      let(:evening)   { create(:shift, :fixed_time, business: business, name: "Evening",
                               start_time: Time.zone.parse("18:00"), end_time: Time.zone.parse("02:00")) }
      # Night: 22:00–06:00 overnight
      let(:night)     { create(:shift, :fixed_time, business: business, name: "Night",
                               start_time: Time.zone.parse("22:00"), end_time: Time.zone.parse("06:00")) }
      # Early morning: 05:00–13:00 (overlaps night 05:00–06:00)
      let(:early)     { create(:shift, :fixed_time, business: business, name: "Early Morning",
                               start_time: Time.zone.parse("05:00"), end_time: Time.zone.parse("13:00")) }
      let(:flexible)  { create(:shift, :hour_based, business: business, name: "Flexible") }

      let(:from) { Date.new(2025, 1, 1) }
      let(:to)   { Date.new(2025, 6, 30) }

      def assign(shift, branch: branch_a, start: from, finish: to)
        create(:shift_assignment, user: user, shift: shift, branch: branch,
               effective_from: start, effective_to: finish)
      end

      def build_assign(shift, branch: branch_b, start: from, finish: to)
        build(:shift_assignment, user: user, shift: shift, branch: branch,
              effective_from: start, effective_to: finish)
      end

      context "non-overnight overlapping shifts" do
        before { assign(morning) }

        it "is invalid when shift times overlap (13:00–21:00 vs 09:00–17:00)" do
          expect(build_assign(afternoon)).not_to be_valid
        end

        it "includes the conflicting shift name and times in the error" do
          bad = build_assign(afternoon)
          bad.valid?
          msg = bad.errors[:base].join
          expect(msg).to include("Morning")
          expect(msg).to include("09:00")
          expect(msg).to include("17:00")
        end

        it "is valid when shift times do not overlap (18:00–02:00 vs 09:00–17:00)" do
          expect(build_assign(evening)).to be_valid
        end
      end

      context "overnight shift overlap detection" do
        before { assign(night) }  # 22:00–06:00

        it "detects overlap when early-morning shift (05:00–13:00) conflicts with overnight" do
          bad = build_assign(early)
          expect(bad).not_to be_valid
          expect(bad.errors[:base].join).to include("Night")
        end

        it "is valid for a shift entirely clear of the overnight window (07:00–21:00)" do
          day = create(:shift, :fixed_time, business: business,
                       start_time: Time.zone.parse("07:00"), end_time: Time.zone.parse("21:00"))
          expect(build_assign(day)).to be_valid
        end
      end

      context "two overnight shifts" do
        before { assign(night) }  # 22:00–06:00

        it "detects overlap with a second overnight shift sharing hours (21:00–05:00)" do
          late_night = create(:shift, :fixed_time, business: business,
                              start_time: Time.zone.parse("21:00"), end_time: Time.zone.parse("05:00"))
          expect(build_assign(late_night)).not_to be_valid
        end
      end

      context "hour_based shifts are excluded from time-overlap checks" do
        before { assign(flexible) }

        it "does not flag a conflict when the existing shift is hour_based" do
          expect(build_assign(morning)).to be_valid
        end

        context "when the new shift is hour_based" do
          # Use a fresh branch so the morning assignment doesn't hit no_overlapping_assignment
          # (branch_a already has the flexible assignment from the outer before).
          let(:branch_c) { create(:branch, business: business) }
          before { assign(morning, branch: branch_c) }

          it "does not flag a conflict for the hour_based new assignment" do
            # build_assign defaults to branch_b which has no existing assignments;
            # no_overlapping_shift_time skips because the new shift is hour_based.
            expect(build_assign(flexible)).to be_valid
          end
        end
      end

      context "non-concurrent date ranges" do
        before { assign(morning, start: Date.new(2025, 1, 1), finish: Date.new(2025, 3, 31)) }

        it "is valid when the assignment periods do not overlap" do
          later = build_assign(afternoon, start: Date.new(2025, 7, 1), finish: Date.new(2025, 12, 31))
          expect(later).to be_valid
        end
      end

      context "across different branches during the same date range" do
        before { assign(morning, branch: branch_a) }

        it "catches time overlap even when branches differ" do
          expect(build_assign(afternoon, branch: branch_b)).not_to be_valid
        end

        it "allows non-overlapping shifts across branches" do
          expect(build_assign(evening, branch: branch_b)).to be_valid
        end
      end

      context "self-exclusion on update" do
        let!(:existing) { assign(morning, branch: branch_a) }

        it "does not flag the assignment against itself when extending effective_to" do
          existing.effective_to = Date.new(2025, 12, 31)
          expect(existing).to be_valid
        end
      end
    end

    describe "no_overlapping_assignment" do
      let(:business)    { create(:business) }
      let(:user)        { create(:user,   business: business) }
      let(:branch)      { create(:branch, business: business) }
      let(:shift)       { create(:shift,  business: business) }

      before do
        create(:shift_assignment,
               user:           user,
               branch:         branch,
               shift:          shift,
               effective_from: Date.new(2025, 1, 1),
               effective_to:   Date.new(2025, 6, 30))
      end

      it "rejects an overlapping assignment for the same user and branch" do
        overlap = build(:shift_assignment,
                        user:           user,
                        branch:         branch,
                        shift:          shift,
                        effective_from: Date.new(2025, 3, 1),
                        effective_to:   nil)
        expect(overlap).not_to be_valid
        expect(overlap.errors[:base]).to be_present
      end

      it "allows a non-overlapping assignment for the same user and branch" do
        non_overlap = build(:shift_assignment,
                            user:           user,
                            branch:         branch,
                            shift:          shift,
                            effective_from: Date.new(2025, 7, 1),
                            effective_to:   nil)
        expect(non_overlap).to be_valid
      end

      it "allows an overlapping date range for a different branch (no_overlapping_assignment is branch-scoped)" do
        other_branch  = create(:branch, business: business)
        evening_shift = create(:shift, :fixed_time, business: business,
                               start_time: Time.zone.parse("18:00"), end_time: Time.zone.parse("22:00"))
        no_conflict = build(:shift_assignment,
                            user:           user,
                            branch:         other_branch,
                            shift:          evening_shift,
                            effective_from: Date.new(2025, 3, 1))
        expect(no_conflict).to be_valid
      end
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:created_by).class_name("User").optional }
    it { is_expected.to belong_to(:ended_by).class_name("User").optional }
  end

  describe "scopes" do
    let(:business)    { create(:business) }
    let(:user)        { create(:user,   business: business) }
    let(:branch)      { create(:branch, business: business) }
    let(:shift)       { create(:shift,  business: business) }

    let!(:active_now) do
      create(:shift_assignment, user: user, branch: branch, shift: shift,
             effective_from: 1.month.ago.to_date, effective_to: nil)
    end
    let!(:past) do
      create(:shift_assignment, user: create(:user, business: business),
             branch: branch, shift: shift,
             effective_from: 6.months.ago.to_date,
             effective_to:   2.months.ago.to_date)
    end
    let!(:future_record) do
      create(:shift_assignment, user: create(:user, business: business),
             branch: branch, shift: shift,
             effective_from: 1.month.from_now.to_date,
             effective_to:   nil)
    end

    describe ".active_on" do
      it "returns assignments active on the given date" do
        expect(ShiftAssignment.active_on(Date.current)).to include(active_now)
        expect(ShiftAssignment.active_on(Date.current)).not_to include(past, future_record)
      end
    end

    describe ".current" do
      it "returns assignments active today" do
        expect(ShiftAssignment.current).to include(active_now)
        expect(ShiftAssignment.current).not_to include(past, future_record)
      end
    end

    describe ".upcoming" do
      it "returns only assignments that start in the future" do
        expect(ShiftAssignment.upcoming).to     include(future_record)
        expect(ShiftAssignment.upcoming).not_to include(active_now, past)
      end
    end

    describe ".expired" do
      it "returns only assignments with an effective_to in the past" do
        expect(ShiftAssignment.expired).to     include(past)
        expect(ShiftAssignment.expired).not_to include(active_now, future_record)
      end
    end
  end

  describe "status helpers" do
    let(:business) { create(:business) }
    let(:user)     { create(:user, business: business) }
    let(:branch)   { create(:branch, business: business) }
    let(:shift)    { create(:shift, business: business) }

    def make_assignment(from:, to: nil)
      build(:shift_assignment, user: user, branch: branch, shift: shift,
            effective_from: from, effective_to: to)
    end

    describe "#future?" do
      it "returns true when effective_from is after today"  do
        expect(make_assignment(from: 2.days.from_now.to_date)).to be_future
      end

      it "returns false when effective_from is today" do
        expect(make_assignment(from: Date.current)).not_to be_future
      end

      it "returns false when effective_from is in the past" do
        expect(make_assignment(from: 1.week.ago.to_date)).not_to be_future
      end
    end

    describe "#current?" do
      it "returns true for an open-ended assignment that started in the past" do
        expect(make_assignment(from: 1.month.ago.to_date)).to be_current
      end

      it "returns true when today is before the effective_to date" do
        expect(make_assignment(from: 1.month.ago.to_date,
                               to:   1.month.from_now.to_date)).to be_current
      end

      it "returns false when effective_to has already passed" do
        expect(make_assignment(from: 2.months.ago.to_date,
                               to:   1.week.ago.to_date)).not_to be_current
      end

      it "returns false when effective_from is still in the future" do
        expect(make_assignment(from: 3.days.from_now.to_date)).not_to be_current
      end
    end

    describe "#historical?" do
      it "returns true when effective_to is in the past" do
        expect(make_assignment(from: 2.months.ago.to_date,
                               to:   1.week.ago.to_date)).to be_historical
      end

      it "returns false when effective_to is nil (open-ended)" do
        expect(make_assignment(from: 1.month.ago.to_date)).not_to be_historical
      end

      it "returns false when effective_to is today or in the future" do
        expect(make_assignment(from: 1.month.ago.to_date,
                               to:   Date.current)).not_to be_historical
      end
    end
  end

  describe "#deletable? and #has_attendance_records?" do
    let(:business)    { create(:business) }
    let(:user)        { create(:user, business: business) }
    let(:branch)      { create(:branch, business: business) }
    let(:shift)       { create(:shift, business: business) }
    let(:assignment)  { create(:shift_assignment, user: user, branch: branch, shift: shift,
                               effective_from: 1.month.from_now.to_date) }

    context "when no attendance records reference the assignment" do
      it "#has_attendance_records? returns false" do
        expect(assignment.has_attendance_records?).to be false
      end

      it "#deletable? returns true" do
        expect(assignment.deletable?).to be true
      end
    end

    context "when an attendance record references the assignment" do
      before do
        AttendanceRecord.create!(
          user:             user,
          branch:           branch,
          shift_assignment: assignment,
          work_date:        Date.current,
          date:             Date.current,
          check_in_at:      Time.zone.parse("#{Date.current} 09:00:00"),
          check_in_source:  "biometric_device",
          late_minutes:     0,
          early_leave_minutes: 0,
          status:           "incomplete"
        )
      end

      it "#has_attendance_records? returns true" do
        expect(assignment.has_attendance_records?).to be true
      end

      it "#deletable? returns false" do
        expect(assignment.deletable?).to be false
      end
    end
  end

  describe "ending an assignment" do
    let(:assignment) { create(:shift_assignment, effective_from: 3.months.ago.to_date, effective_to: nil) }

    it "becomes inactive after effective_to is set" do
      assignment.update!(effective_to: Date.current)
      expect(ShiftAssignment.active_on(Date.current + 1.day)).not_to include(assignment)
    end

    it "remains active on the effective_to date itself" do
      assignment.update!(effective_to: Date.current)
      expect(ShiftAssignment.active_on(Date.current)).to include(assignment)
    end

    it "is invalid when ended_on is set to before effective_from" do
      assignment.effective_to = assignment.effective_from - 1.day
      expect(assignment).not_to be_valid
      expect(assignment.errors[:effective_to]).to be_present
    end

    it "is valid when ended_on is after effective_from" do
      assignment.effective_to = assignment.effective_from + 1.day
      expect(assignment).to be_valid
    end

    it "does not affect historical attendance records" do
      business  = assignment.user.business
      shift     = assignment.shift
      rec = create(:attendance_record,
                   user:             assignment.user,
                   shift_assignment: assignment,
                   work_date:        1.week.ago.to_date)
      assignment.update!(effective_to: Date.current)
      expect(rec.reload.shift_assignment_id).to eq(assignment.id)
    end
  end

  describe "delegations" do
    it "delegates shift_name to shift#name" do
      assignment = build(:shift_assignment)
      expect(assignment.shift_name).to eq(assignment.shift.name)
    end

    it "delegates branch_name to branch#name" do
      assignment = build(:shift_assignment)
      expect(assignment.branch_name).to eq(assignment.branch.name)
    end
  end
end
