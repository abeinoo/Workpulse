require "rails_helper"

# Characterization (Department + JobTitle pilot, M1 gap DJ1) — the CURRENT
# Department model contract. Department is a Workforce catalogue; these
# examples must keep passing unchanged through any later boundary/location step.
RSpec.describe "Characterization: Department model", type: :model do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  describe "ownership, normalization and validation" do
    it "belongs to a business and is listed only for it" do
      own     = create(:department, business: business)
      foreign = create(:department, business: other)
      expect(Department.for_business(business)).to contain_exactly(own)
      expect(Department.for_business(business)).not_to include(foreign)
    end

    it "trims and collapses whitespace in the name" do
      expect(Department.create!(business: business, name: "  Reception   Desk ").name).to eq("Reception Desk")
    end

    it "rejects a case-insensitive duplicate within the business, but allows the name in another business" do
      Department.create!(business: business, name: "Reception Desk")
      duplicate = Department.new(business: business, name: "reception desk")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors.details[:name]).to include(a_hash_including(error: :taken))
      expect(Department.new(business: other, name: "Reception Desk")).to be_valid
    end

    it "requires a name (whitespace-only normalizes to blank) of at most 100 characters" do
      blank = Department.new(business: business, name: "   ")
      expect(blank).not_to be_valid
      expect(blank.errors.details[:name]).to include(a_hash_including(error: :blank))
      expect(Department.new(business: business, name: "x" * 101)).not_to be_valid
      expect(Department.new(business: business, name: "x" * 100)).to be_valid
    end
  end

  describe "soft delete (active flag)" do
    it "deactivate!/activate! toggle membership of the active scope" do
      department = create(:department, business: business)
      department.deactivate!
      expect(Department.for_business(business).active).not_to include(department)
      department.activate!
      expect(Department.for_business(business).active).to include(department)
    end
  end

  describe "deletion" do
    it "nullifies employees' department link when a department without dependents is destroyed" do
      department = create(:department, business: business)
      employee   = create(:user, business: business, department: department)
      expect(department.destroy).to be_truthy
      expect(employee.reload.department_id).to be_nil
    end

    it "is restricted while evaluation templates depend on it" do
      department = create(:department, business: business)
      EvaluationTemplate.create!(business: business, department: department, name: "Template")
      expect(department.destroy).to be(false)
      expect(department.errors.full_messages).to eq([ "Cannot delete record because dependent evaluation templates exist" ])
      expect(Department.exists?(department.id)).to be(true)
    end

    it "is restricted while performance reviews depend on it" do
      department = create(:department, business: business)
      create(:performance_review, business: business, department: department)
      expect(department.destroy).to be(false)
      expect(department.errors.full_messages).to eq([ "Cannot delete record because dependent performance reviews exist" ])
    end
  end

  describe "contracts relied upon by Performance (Workforce consumer)" do
    let(:department) { create(:department, business: business) }
    let(:template)   { EvaluationTemplate.create!(business: business, department: department, name: "Template") }
    let(:criterion)  { EvaluationCriterion.create!(evaluation_template: template, name: "Punctuality") }
    let(:observer)   { create(:user, business: business) }

    def observation(employee)
      PerformanceObservation.new(business: business, evaluation_criterion: criterion, employee: employee,
                                 observed_by: observer, observation_date: Date.current, observation_type: "positive")
    end

    it "accepts an observation whose criterion belongs to the employee's department" do
      expect(observation(create(:user, business: business, department: department))).to be_valid
    end

    it "rejects an observation for an employee of another department, or without a department" do
      elsewhere = observation(create(:user, business: business, department: create(:department, business: business)))
      expect(elsewhere).not_to be_valid
      expect(elsewhere.errors.details[:evaluation_criterion_id]).to include(a_hash_including(error: :department_mismatch))

      none = observation(create(:user, business: business, department: nil))
      expect(none).not_to be_valid
      expect(none.errors.details[:employee]).to include(a_hash_including(error: :without_department))
    end
  end
end
