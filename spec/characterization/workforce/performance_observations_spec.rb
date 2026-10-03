require "rails_helper"

# Characterization (Pilot 3, M1 group 3) — CURRENT performance observation
# visibility and edit rules. Cross-business reference rejection on create is
# in spec/requests/security/performance_cross_business_spec.rb (SEC-P3-1);
# department consistency in spec/characterization/workforce/department_spec.rb.
RSpec.describe "Characterization: performance observations", type: :request do
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let(:department) { create(:department, business: business) }
  let(:template)   { EvaluationTemplate.create!(business: business, department: department, name: "Template") }
  let(:criterion)  { EvaluationCriterion.create!(evaluation_template: template, name: "Punctuality") }
  let(:branch_a)   { create(:branch, business: business) }
  let(:branch_b)   { create(:branch, business: business) }
  let(:emp_a)      { create(:user, business: business, department: department) }
  let(:emp_b)      { create(:user, business: business, department: department) }
  let(:observer) do
    api_user_with(business, :view_notes, :create_observations,
                  scopes: { "view_notes" => "business", "create_observations" => "business" })
  end

  before do
    create(:shift_assignment, user: emp_a, branch: branch_a, shift: create(:shift, :fixed_time, business: business))
    create(:shift_assignment, user: emp_b, branch: branch_b, shift: create(:shift, :fixed_time, business: business))
  end

  def observation(employee:, by:, note: "Note")
    PerformanceObservation.create!(business: business, evaluation_criterion: criterion, employee: employee, observed_by: by,
                                   observation_date: Date.current, observation_type: "positive", note: note)
  end

  def visible_to(user) = PerformanceObservationPolicy::Scope.new(user, PerformanceObservation).resolve

  describe "visibility" do
    it "business-scoped viewers and the owner see every observation of the business, never another business's" do
      own = [ observation(employee: emp_a, by: observer), observation(employee: emp_b, by: owner) ]
      expect(visible_to(observer)).to match_array(own)
      expect(visible_to(owner)).to match_array(own)
    end

    it "a branch-scoped viewer sees only observations of employees in their managed branch" do
      in_a = observation(employee: emp_a, by: owner)
      observation(employee: emp_b, by: owner)
      branch_viewer = api_user_with(business, :view_notes, scopes: { "view_notes" => "branch" })
      branch_a.update!(branch_manager: branch_viewer)
      expect(visible_to(branch_viewer)).to contain_exactly(in_a)
    end

    it "an employee without observation permissions cannot open the module at all" do
      observation(employee: emp_a, by: observer)
      sign_in emp_a
      get performance_observations_path
      expect(response).to redirect_to(root_path)
    end

    it "another business's observation is 404 even for the owner" do
      other      = create(:business)
      other_dept = create(:department, business: other)
      other_crit = EvaluationCriterion.create!(evaluation_template: EvaluationTemplate.create!(business: other, department: other_dept, name: "T"), name: "C")
      other_emp  = create(:user, business: other, department: other_dept)
      foreign = PerformanceObservation.create!(business: other, evaluation_criterion: other_crit, employee: other_emp,
                                               observed_by: create(:user, business: other), observation_date: Date.current,
                                               observation_type: "neutral")
      sign_in owner
      get performance_observation_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "create" do
    it "records the signed-in user as observer, in the actor's business" do
      sign_in observer
      post performance_observations_path, params: { performance_observation: {
        employee_id: emp_a.id, evaluation_criterion_id: criterion.id, observation_date: Date.current, observation_type: "negative", note: "Late"
      } }
      expect(response).to redirect_to(performance_observations_path)
      expect(PerformanceObservation.last).to have_attributes(observed_by_id: observer.id, business_id: business.id, observation_type: "negative")
    end

    it "is refused without create_observations" do
      sign_in api_user_with(business, :view_notes, scopes: { "view_notes" => "business" })
      expect {
        post performance_observations_path, params: { performance_observation: {
          employee_id: emp_a.id, evaluation_criterion_id: criterion.id, observation_date: Date.current, observation_type: "positive"
        } }
      }.not_to change(PerformanceObservation, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "edit rules (observer or owner only)" do
    let!(:mine) { observation(employee: emp_a, by: observer) }

    it "the author can update and delete their observation" do
      sign_in observer
      patch performance_observation_path(mine), params: { performance_observation: { note: "Revised" } }
      expect(mine.reload.note).to eq("Revised")
      sign_in observer
      delete performance_observation_path(mine)
      expect(PerformanceObservation.exists?(mine.id)).to be(false)
    end

    it "the owner can update another user's observation" do
      sign_in owner
      patch performance_observation_path(mine), params: { performance_observation: { note: "Owner edit" } }
      expect(mine.reload.note).to eq("Owner edit")
    end

    it "another user with create_observations can neither update nor delete it" do
      colleague = api_user_with(business, :view_notes, :create_observations,
                                scopes: { "view_notes" => "business", "create_observations" => "business" })
      sign_in colleague
      patch performance_observation_path(mine), params: { performance_observation: { note: "Hijacked" } }
      expect(response).to redirect_to(root_path)
      expect(mine.reload.note).to eq("Note")
      sign_in colleague
      delete performance_observation_path(mine)
      expect(PerformanceObservation.exists?(mine.id)).to be(true)
    end
  end
end
