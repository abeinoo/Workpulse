require "rails_helper"

# Characterization (Pilot 3, M1 group 4) — CURRENT /admin/evaluation_templates
# behaviour. Cross-business department rejection is in
# spec/requests/security/performance_cross_business_spec.rb (SEC-P3-1).
RSpec.describe "Characterization: evaluation template administration", type: :request do
  let(:business)   { create(:business) }
  let(:department) { create(:department, business: business) }
  let(:admin)      { api_user_with(business, :view_performance_dashboard, :manage_evaluation_templates) }

  def template_with_criteria(name: "Template", criteria: %w[Punctuality Attitude])
    EvaluationTemplate.create!(business: business, department: department, name: name).tap do |t|
      criteria.each_with_index { |c, i| EvaluationCriterion.create!(evaluation_template: t, name: c, sort_order: i) }
    end
  end

  describe "authorization and isolation" do
    it "is available with manage_evaluation_templates or manage_settings" do
      [ admin, api_user_with(business, :manage_settings) ].each do |user|
        sign_in user
        get admin_evaluation_templates_path
        expect(response).to have_http_status(:ok)
      end
    end

    it "is refused without either permission" do
      sign_in api_user_with(business, :view_employees, :manage_employees)
      get admin_evaluation_templates_path
      expect(response).to redirect_to(root_path)
    end

    it "lists only this business's templates; another business's template is 404" do
      own     = template_with_criteria(name: "Own Template")
      other   = create(:business)
      foreign = EvaluationTemplate.create!(business: other, department: create(:department, business: other), name: "Foreign Template")
      sign_in admin
      get admin_evaluation_templates_path
      expect(response.body).to include(own.name)
      expect(response.body).not_to include(foreign.name)
      sign_in admin
      get admin_evaluation_template_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "create / update with nested criteria" do
    before { sign_in admin }

    it "creates a template with its criteria, ignoring blank criterion rows" do
      post admin_evaluation_templates_path, params: { evaluation_template: {
        name: "Front Desk", department_id: department.id, active: "1",
        evaluation_criteria_attributes: { "0" => { name: "Greeting", sort_order: 0, active: "1" },
                                          "1" => { name: "", sort_order: 1, active: "1" } }
      } }
      template = EvaluationTemplate.find_by!(name: "Front Desk")
      expect(response).to redirect_to(admin_evaluation_template_path(template))
      expect(template.business_id).to eq(business.id)
      expect(template.evaluation_criteria.pluck(:name)).to eq(%w[Greeting])
    end

    it "re-renders 422 without a name" do
      post admin_evaluation_templates_path, params: { evaluation_template: { name: "", department_id: department.id } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "updates the name, adds a criterion and removes an unused one" do
      template = template_with_criteria
      unused   = template.evaluation_criteria.find_by!(name: "Attitude")
      patch admin_evaluation_template_path(template), params: { evaluation_template: {
        name: "Renamed",
        evaluation_criteria_attributes: { "0" => { id: unused.id, _destroy: "1" },
                                          "1" => { name: "Teamwork", sort_order: 5, active: "1" } }
      } }
      expect(response).to redirect_to(admin_evaluation_template_path(template))
      expect(template.reload.name).to eq("Renamed")
      expect(template.evaluation_criteria.pluck(:name)).to contain_exactly("Punctuality", "Teamwork")
    end
  end

  describe "deletion and history protection" do
    before { sign_in admin }

    it "deletes a template whose criteria have no scores or observations (criteria go with it)" do
      template = template_with_criteria
      delete admin_evaluation_template_path(template)
      expect(response).to redirect_to(admin_evaluation_templates_path)
      expect(EvaluationTemplate.exists?(template.id)).to be(false)
      expect(EvaluationCriterion.where(evaluation_template_id: template.id)).to be_empty
    end

    it "refuses to delete a template whose criterion has been scored, keeping template, criteria and scores" do
      template  = template_with_criteria
      criterion = template.evaluation_criteria.first
      review = create(:performance_review, business: business, department: department)
      score  = review.performance_review_scores.create!(evaluation_criterion: criterion, score: 4)
      expect { delete admin_evaluation_template_path(template) }.not_to change(EvaluationCriterion, :count)
      expect(response).to redirect_to(admin_evaluation_templates_path)
      expect(flash[:notice]).to be_nil # no false "deleted" message
      expect(EvaluationTemplate.exists?(template.id)).to be(true)
      expect(PerformanceReviewScore.exists?(score.id)).to be(true)
    end

    it "keeps a template whose criterion has observations" do
      template  = template_with_criteria
      criterion = template.evaluation_criteria.first
      employee  = create(:user, business: business, department: department)
      observation = PerformanceObservation.create!(business: business, evaluation_criterion: criterion, employee: employee,
                                                   observed_by: create(:user, business: business),
                                                   observation_date: Date.current, observation_type: "neutral")
      delete admin_evaluation_template_path(template)
      expect(EvaluationTemplate.exists?(template.id)).to be(true)
      expect(PerformanceObservation.exists?(observation.id)).to be(true)
    end

    # KNOWN DEFECT PERF-D2 (pre-existing, not fixed in Pilot 3): the restriction
    # error lands on the nested criterion, so EvaluationTemplate#errors stays
    # empty and the controller redirects with an EMPTY alert — the admin is not
    # told why nothing was deleted. Pinned so a fix is a deliberate change.
    it "records the restriction on the criterion, not the template, so the alert is empty (known defect PERF-D2)" do
      template  = template_with_criteria
      criterion = template.evaluation_criteria.first
      review = create(:performance_review, business: business, department: department)
      review.performance_review_scores.create!(evaluation_criterion: criterion, score: 4)
      expect(template.destroy).to be(false)
      expect(template.errors).to be_empty
      expect(template.evaluation_criteria.find { |c| c.id == criterion.id }.errors.full_messages)
        .to include(a_string_matching(/Cannot delete record because dependent performance review scores exist/))
      delete admin_evaluation_template_path(template)
      expect(flash[:alert]).to eq("")
    end

    it "a scored criterion cannot be destroyed directly (restrict); it is retired by deactivation" do
      template  = template_with_criteria
      criterion = template.evaluation_criteria.first
      review = create(:performance_review, business: business, department: department)
      review.performance_review_scores.create!(evaluation_criterion: criterion, score: 5)
      expect(criterion.destroy).to be(false)
      criterion.deactivate!
      expect(template.active_criteria).not_to include(criterion)
    end
  end

  describe "active template and criteria (consumed by the review screen)" do
    it "the review composer uses the department's first active template and only its active criteria, in sort order" do
      inactive = EvaluationTemplate.create!(business: business, department: department, name: "A Old", active: false)
      EvaluationCriterion.create!(evaluation_template: inactive, name: "Old")
      template = template_with_criteria(name: "B Current", criteria: %w[Second First])
      template.evaluation_criteria.find_by!(name: "First").update!(sort_order: 0)
      template.evaluation_criteria.find_by!(name: "Second").update!(sort_order: 1)
      EvaluationCriterion.create!(evaluation_template: template, name: "Retired", sort_order: 2, active: false)

      employee = create(:user, business: business, department: department)
      composer = Performance::ReviewComposer.new(employee: employee, year: 2026, month: 5)
      expect(composer.template).to eq(template)
      expect(composer.criterion_rows.map { |row| row.criterion.name }).to eq(%w[First Second])
    end
  end
end
