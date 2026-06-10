require "rails_helper"

RSpec.describe Scheduling::TemplatePreviewer do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:shift)     { create(:shift, :fixed_time, business: business) }
  let(:creator)   { create(:user, business: business) }
  let(:employee)  { create(:user, business: business) }
  let(:template)  { create(:shift_template, business: business, created_by: creator) }

  let(:starts_on) { Date.new(2026, 7, 1) }
  let(:ends_on)   { Date.new(2026, 7, 7) }

  before do
    create(:shift_template_entry,
           shift_template: template,
           shift:          shift,
           branch:         branch,
           starts_on:      starts_on,
           ends_on:        ends_on)
  end

  subject do
    described_class.call(
      template:  template,
      employees: [ employee ]
    )
  end

  describe "#call" do
    it "returns one PreviewRow per (employee × entry)" do
      expect(subject.size).to eq(1)
    end

    it "sets effective_from from entry.starts_on" do
      row = subject.first
      expect(row.effective_from).to eq(starts_on)
    end

    it "sets effective_to from entry.ends_on" do
      row = subject.first
      expect(row.effective_to).to eq(ends_on)
    end

    it "uses starts_on as effective_to when ends_on is nil" do
      template.entries.first.update!(ends_on: nil)
      row = subject.first
      expect(row.effective_to).to eq(starts_on)
    end

    context "when the employee already has an overlapping assignment" do
      before do
        create(:shift_assignment,
               user:           employee,
               branch:         branch,
               shift:          shift,
               effective_from: starts_on - 30.days,
               effective_to:   nil)
      end

      it "returns a blocked row" do
        row = subject.first
        expect(row.blocked?).to be true
        expect(row.conflict).not_to be_nil
      end
    end

    context "when the employee is not in the branch" do
      it "returns a warning row" do
        row = subject.first
        expect(row.warning?).to be true
        expect(row.conflict.reason).to eq(:branch_mismatch)
      end
    end

    context "when employee is in the branch and no conflicts exist" do
      # Prior (non-overlapping) history at the branch → no branch-mismatch warning.
      before do
        create(:shift_assignment, user: employee, branch: branch, shift: shift,
               effective_from: Date.new(2026, 1, 1), effective_to: Date.new(2026, 1, 7))
      end

      it "returns a valid row with no conflict" do
        row = subject.first
        expect(row.valid?).to be true
        expect(row.conflict).to be_nil
      end
    end

    it "generates rows for all employees" do
      other_employee = create(:user, business: business)
      rows = described_class.call(
        template:  template,
        employees: [ employee, other_employee ]
      )
      expect(rows.size).to eq(2)
      expect(rows.map(&:user)).to contain_exactly(employee, other_employee)
    end

    it "generates rows for all template entries" do
      create(:shift_template_entry,
             shift_template: template,
             shift:          shift,
             branch:         nil,
             starts_on:      starts_on + 10.days)
      rows = described_class.call(
        template:  template,
        employees: [ employee ]
      )
      expect(rows.size).to eq(2)
    end

    it "returns empty when the template has no entries" do
      template.entries.destroy_all
      expect(subject).to be_empty
    end
  end
end
