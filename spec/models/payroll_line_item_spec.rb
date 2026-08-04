require "rails_helper"

RSpec.describe PayrollLineItem, type: :model do
  let(:entry) { create(:payroll_entry) }

  describe "#deduction_waivable?" do
    PayrollLineItem::WAIVABLE_DEDUCTION_TYPES.each do |type|
      it "is waivable for #{type} (on the allowlist, negative amount)" do
        li = create(:payroll_line_item, payroll_entry: entry, item_type: type,
                    amount: -10.0, review_status: "approved")
        expect(li.deduction_waivable?).to be true
      end
    end

    %w[advance_deduction obligation_deduction insurance_deduction].each do |type|
      it "is NOT waivable for #{type} (deliberately excluded until explicitly supported)" do
        li = create(:payroll_line_item, payroll_entry: entry, item_type: type,
                    amount: -10.0, review_status: "approved")
        expect(li.deduction_waivable?).to be false
      end
    end

    it "is not waivable for an addition (positive amount), even if the type is on the allowlist" do
      li = create(:payroll_line_item, payroll_entry: entry, item_type: "manual_deduction",
                  amount: 10.0, review_status: "approved")
      expect(li.deduction_waivable?).to be false
    end

    it "is not waivable for a non-deduction type not on the allowlist (e.g. overtime)" do
      li = create(:payroll_line_item, :overtime, payroll_entry: entry)
      expect(li.deduction_waivable?).to be false
    end
  end

  describe "#waiver_identity" do
    it "keys on [item_type, source_id] when a source record exists" do
      li = create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty",
                  amount: -10.0, review_status: "approved",
                  source_type: "AttendanceRecord", source_id: 555)
      expect(li.waiver_identity).to eq([ "late_penalty", 555 ])
    end

    it "keys on [item_type] alone when there is no source record (e.g. absence)" do
      li = create(:payroll_line_item, payroll_entry: entry, item_type: "manual_adjustment",
                  amount: -10.0, review_status: "approved", source_type: nil, source_id: nil)
      expect(li.waiver_identity).to eq([ "manual_adjustment" ])
    end
  end
end
