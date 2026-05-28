require "rails_helper"

RSpec.describe ShiftTemplateEntry, type: :model do
  let(:business)  { create(:business) }
  let(:template)  { create(:shift_template, business: business) }
  let(:shift)     { create(:shift, business: business) }
  let(:branch)    { create(:branch, business: business) }

  describe "associations" do
    it { is_expected.to belong_to(:shift_template) }
    it { is_expected.to belong_to(:shift) }
    it { is_expected.to belong_to(:branch).optional }
  end

  describe "validations" do
    subject do
      build(:shift_template_entry, shift_template: template, shift: shift,
            starts_on: Date.current)
    end

    it { is_expected.to be_valid }

    it "is invalid without starts_on" do
      subject.starts_on = nil
      expect(subject).not_to be_valid
      expect(subject.errors[:starts_on]).to be_present
    end

    it "is invalid without a shift" do
      subject.shift = nil
      expect(subject).not_to be_valid
    end

    it "allows branch to be nil (any branch)" do
      subject.branch = nil
      expect(subject).to be_valid
    end

    it "is valid with a specific branch" do
      subject.branch = branch
      expect(subject).to be_valid
    end

    it "is valid without a weekday (now optional)" do
      subject.weekday = nil
      expect(subject).to be_valid
    end

    it "is invalid with weekday outside 0-6" do
      subject.weekday = 7
      expect(subject).not_to be_valid
    end

    it "is valid for all weekday values 0-6" do
      (0..6).each do |day|
        entry = build(:shift_template_entry, shift_template: template, shift: shift,
                      starts_on: Date.current, weekday: day)
        expect(entry).to be_valid, "Expected weekday #{day} to be valid"
      end
    end

    describe "ends_on" do
      it "is valid when nil (single-day coverage)" do
        subject.ends_on = nil
        expect(subject).to be_valid
      end

      it "is valid when equal to starts_on" do
        subject.ends_on = subject.starts_on
        expect(subject).to be_valid
      end

      it "is valid when after starts_on" do
        subject.ends_on = subject.starts_on + 7.days
        expect(subject).to be_valid
      end

      it "is invalid when before starts_on" do
        subject.starts_on = Date.current
        subject.ends_on   = Date.current - 1.day
        expect(subject).not_to be_valid
        expect(subject.errors[:ends_on]).to be_present
      end
    end

    describe "effective_from_offset" do
      it "is valid when nil" do
        subject.effective_from_offset = nil
        expect(subject).to be_valid
      end

      it "must be >= 0 when present" do
        subject.effective_from_offset = -1
        expect(subject).not_to be_valid
      end
    end

    describe "effective_to_offset" do
      it "must be > 0 when present" do
        subject.effective_to_offset = 0
        expect(subject).not_to be_valid
      end

      it "is valid when nil" do
        subject.effective_to_offset = nil
        expect(subject).to be_valid
      end
    end
  end

  describe "#effective_ends_on" do
    it "returns starts_on when ends_on is nil" do
      entry = build(:shift_template_entry, starts_on: Date.current, ends_on: nil)
      expect(entry.effective_ends_on).to eq(Date.current)
    end

    it "returns ends_on when present" do
      entry = build(:shift_template_entry, starts_on: Date.current,
                    ends_on: Date.current + 6.days)
      expect(entry.effective_ends_on).to eq(Date.current + 6.days)
    end
  end

  describe "#day_span" do
    it "returns 1 for a single-day entry" do
      entry = build(:shift_template_entry, starts_on: Date.current, ends_on: nil)
      expect(entry.day_span).to eq(1)
    end

    it "returns correct count for multi-day entry" do
      entry = build(:shift_template_entry, starts_on: Date.new(2026, 6, 1),
                    ends_on: Date.new(2026, 6, 7))
      expect(entry.day_span).to eq(7)
    end
  end

  describe "#weekday_name" do
    it "returns the correct weekday name for index 0" do
      entry = build(:shift_template_entry, weekday: 0)
      expect(entry.weekday_name).to eq("sunday")
    end

    it "returns nil when weekday is nil" do
      entry = build(:shift_template_entry, weekday: nil)
      expect(entry.weekday_name).to be_nil
    end
  end

  describe "delegations" do
    it "delegates shift_name to shift#name" do
      entry = build(:shift_template_entry, shift: shift)
      expect(entry.shift_name).to eq(shift.name)
    end

    it "delegates branch_name to branch#name (nil when no branch)" do
      entry = build(:shift_template_entry, branch: nil)
      expect(entry.branch_name).to be_nil
    end

    it "delegates branch_name to branch#name when branch present" do
      entry = build(:shift_template_entry, branch: branch)
      expect(entry.branch_name).to eq(branch.name)
    end
  end
end
