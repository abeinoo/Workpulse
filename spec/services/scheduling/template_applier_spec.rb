require "rails_helper"

RSpec.describe Scheduling::TemplateApplier do
  let(:business)   { create(:business) }
  let(:branch)     { create(:branch, business: business) }
  let(:shift)      { create(:shift, :fixed_time, business: business) }
  let(:creator)    { create(:user, business: business) }
  let(:employee)   { create(:user, business: business) }
  let(:template)   { create(:shift_template, business: business, created_by: creator) }

  let(:starts_on) { Date.new(2026, 8, 1) }
  let(:ends_on)   { Date.new(2026, 8, 31) }

  before do
    create(:shift_template_entry,
           shift_template: template,
           shift:          shift,
           branch:         nil,
           starts_on:      starts_on,
           ends_on:        ends_on)
  end

  def apply(**overrides)
    described_class.call(
      template:   overrides.fetch(:template, template),
      employees:  overrides.fetch(:employees, [ employee ]),
      created_by: overrides.fetch(:created_by, creator)
    )
  end

  describe "#call" do
    context "with no conflicts" do
      it "creates a ShiftAssignment for each (employee, entry) pair" do
        expect { apply }.to change(ShiftAssignment, :count).by(1)
      end

      it "returns a Result with created=1 and skipped=0" do
        result = apply
        expect(result.created).to eq(1)
        expect(result.skipped).to eq(0)
        expect(result.row_errors).to be_empty
        expect(result.success?).to be true
      end

      it "sets created_by on the resulting assignment" do
        apply
        assignment = ShiftAssignment.last
        expect(assignment.created_by).to eq(creator)
      end

      it "sets source_template on the resulting assignment" do
        apply
        assignment = ShiftAssignment.last
        expect(assignment.source_template).to eq(template)
      end

      it "sets the correct date range on the assignment from entry dates" do
        apply
        assignment = ShiftAssignment.last
        expect(assignment.effective_from).to eq(starts_on)
        expect(assignment.effective_to).to eq(ends_on)
      end
    end

    context "when the employee is inactive (blocked row)" do
      before { employee.update!(active: false) }

      it "does NOT create an assignment" do
        expect { apply }.not_to change(ShiftAssignment, :count)
      end

      it "counts the row as skipped" do
        result = apply
        expect(result.created).to eq(0)
        expect(result.skipped).to eq(1)
      end
    end

    context "when an overlapping assignment exists" do
      before do
        create(:shift_assignment,
               user:           employee,
               shift:          shift,
               branch:         nil,
               effective_from: starts_on - 60.days,
               effective_to:   nil)
      end

      it "does not create the overlapping assignment" do
        expect { apply }.not_to change(ShiftAssignment, :count)
      end

      it "records a row_error or skipped row (blocked by previewer)" do
        result = apply
        expect(result.skipped + result.row_errors.size).to be >= 1
      end
    end

    context "with multiple employees" do
      let(:other_employee) { create(:user, business: business) }

      it "creates assignments for all employees" do
        expect { apply(employees: [ employee, other_employee ]) }
          .to change(ShiftAssignment, :count).by(2)
      end

      it "reports correct counts in result" do
        result = apply(employees: [ employee, other_employee ])
        expect(result.created).to eq(2)
        expect(result.skipped).to eq(0)
      end
    end

    context "with multiple entries for different branches" do
      let(:branch_b) { create(:branch, business: business) }
      let(:shift_b)  { create(:shift, :hour_based, business: business) }

      before do
        create(:shift_template_entry,
               shift_template: template,
               shift:          shift_b,
               branch:         branch_b,
               starts_on:      starts_on + 1.day,
               ends_on:        ends_on)
      end

      it "creates one assignment per entry" do
        expect { apply }.to change(ShiftAssignment, :count).by(2)
      end
    end

    it "returns empty result when template has no entries" do
      template.entries.destroy_all
      result = apply
      expect(result.created).to eq(0)
      expect(result.skipped).to eq(0)
    end
  end
end
