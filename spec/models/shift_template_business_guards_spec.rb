require "rails_helper"

# BUG-031 — shift templates and shift assignments never reference another
# business's shift, rule profile or employee, through any write path: template
# entries (nested form), template application (Scheduling::TemplateApplier), and
# a direct ShiftAssignment write.
RSpec.describe "Shift template and assignment business guards (BUG-031)", type: :model do
  let(:business)      { create(:business) }
  let(:other)         { create(:business) }
  let(:owner)         { create(:user, business: business) }
  let(:employee)      { create(:user, business: business) }
  let(:branch)        { create(:branch, business: business) }
  let(:shift)         { create(:shift, :fixed_time, business: business) }
  let(:profile)       { create(:shift_rule_profile, business: business) }
  let(:foreign_shift) { create(:shift, :fixed_time, business: other) }
  let(:foreign_rules) { create(:shift_rule_profile, business: other) }

  def new_template(**entry)
    ShiftTemplate.new(name: "T-#{SecureRandom.hex(3)}", business: business, created_by: owner,
                      entries_attributes: [ { shift_id: shift.id, starts_on: Date.current }.merge(entry) ])
  end

  describe ShiftTemplateEntry do
    it "refuses another business's shift through the nested template form, saving nothing" do
      template = new_template(shift_id: foreign_shift.id)

      expect(template.save).to be(false)
      expect(template.entries.first.errors.where(:shift_id, :other_business)).to be_present
      expect(ShiftTemplate.count).to eq(0)
      expect(ShiftTemplateEntry.count).to eq(0)
    end

    it "refuses another business's rule profile" do
      template = new_template(shift_rule_profile_id: foreign_rules.id)

      expect(template.save).to be(false)
      expect(template.entries.first.errors.where(:shift_rule_profile_id, :other_business)).to be_present
    end

    it "refuses an existing entry updated to a foreign shift or rule profile" do
      template = new_template(shift_rule_profile_id: profile.id).tap(&:save!)
      entry    = template.entries.first

      expect(entry.update(shift_id: foreign_shift.id)).to be(false)
      expect(entry.reload.update(shift_rule_profile_id: foreign_rules.id)).to be(false)
      expect(entry.reload).to have_attributes(shift_id: shift.id, shift_rule_profile_id: profile.id)
    end

    it "accepts its own business's shift and rule profile" do
      expect(new_template(shift_rule_profile_id: profile.id).save).to be(true)
    end
  end

  describe ShiftAssignment do
    def assignment(**attrs)
      ShiftAssignment.new({ user: employee, shift: shift, branch: branch,
                            effective_from: BusinessDay.current(context: business) }.merge(attrs))
    end

    it "refuses another business's shift, rule profile or employee on a direct write" do
      { shift: foreign_shift, rule_profile: foreign_rules, user: create(:user, business: other) }.each do |key, record|
        record_assignment = assignment(key => record)
        expect(record_assignment.save).to be(false), key.to_s
        attribute = { shift: :shift_id, rule_profile: :shift_rule_profile_id, user: :user_id }.fetch(key)
        expect(record_assignment.errors.where(attribute, :other_business)).to be_present
      end
      expect(ShiftAssignment.count).to eq(0)
    end

    it "accepts its own business's shift, rule profile and employee" do
      expect(assignment(rule_profile: profile).save).to be(true)
    end

    it "does not re-check an existing assignment that only has its end date changed" do
      legacy = assignment.tap(&:save!)
      legacy.update_column(:shift_id, foreign_shift.id) # a row written before the guard

      expect(legacy.reload.update(effective_to: BusinessDay.current(context: business))).to be(true)
    end
  end

  describe Scheduling::TemplateApplier do
    it "creates no assignment from an entry naming another business's shift" do
      template = new_template.tap(&:save!)
      template.entries.first.update_column(:shift_id, foreign_shift.id) # bypasses the entry guard

      result = described_class.call(template: template.reload, employees: [ employee ], branch: branch,
                                    created_by: owner)

      # The preview runs the same ShiftAssignment validation and blocks the row.
      expect(result.created).to eq(0)
      expect(result.skipped + result.row_errors.size).to eq(1)
      expect(ShiftAssignment.count).to eq(0)
    end

    it "still applies a same-business template" do
      template = new_template(shift_rule_profile_id: profile.id).tap(&:save!)

      result = described_class.call(template: template, employees: [ employee ], branch: branch, created_by: owner)

      expect(result.created).to eq(1)
      expect(ShiftAssignment.last).to have_attributes(shift_id: shift.id, shift_rule_profile_id: profile.id)
    end
  end
end
