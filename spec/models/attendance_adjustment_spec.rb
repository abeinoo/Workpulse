require "rails_helper"

RSpec.describe AttendanceAdjustment, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:attendance_record) }
    it { is_expected.to belong_to(:adjusted_by).class_name("User") }
  end

  describe "validations" do
    subject { build(:attendance_adjustment) }

    it { is_expected.to validate_presence_of(:field_name) }
    it { is_expected.to validate_presence_of(:reason) }
  end

  describe "immutability" do
    let!(:adjustment) { create(:attendance_adjustment) }

    it "cannot be updated" do
      expect { adjustment.update!(reason: "changed") }.to raise_error(ActiveRecord::RecordNotSaved)
    end

    it "cannot be destroyed" do
      expect { adjustment.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    end

    it "persists the original values after an attempted update" do
      original_reason = adjustment.reason
      begin
        adjustment.update(reason: "changed")
      rescue
        nil
      end
      expect(adjustment.reload.reason).to eq(original_reason)
    end
  end
end
