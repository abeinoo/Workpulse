require "rails_helper"

# SEC-P3-1: Performance writes must never reference another business's records.
# Each create path builds through current_user.business; the referenced
# department / employee / criterion ids come from params and are now validated
# to belong to the same business (model-level, so every write path is covered).
RSpec.describe "Security: Performance cross-business references", type: :request do
  let(:business)     { create(:business) }
  let(:other)        { create(:business) }
  let!(:owner)       { create(:user, :owner, business: business) }
  let(:department)   { create(:department, business: business) }
  let(:employee)     { create(:user, business: business, department: department) }
  let(:template)     { EvaluationTemplate.create!(business: business, department: department, name: "Own template") }
  let(:criterion)    { EvaluationCriterion.create!(evaluation_template: template, name: "Own criterion") }

  let(:foreign_department) { create(:department, business: other) }
  let(:foreign_employee)   { create(:user, business: other, department: foreign_department) }
  let(:foreign_criterion) do
    EvaluationCriterion.create!(evaluation_template: EvaluationTemplate.create!(business: other, department: foreign_department, name: "Foreign"),
                                name: "Foreign criterion")
  end

  describe "evaluation templates" do
    before { sign_in api_user_with(business, :view_performance_dashboard, :manage_evaluation_templates) }

    it "rejects another business's department on create (422, nothing saved)" do
      expect {
        post admin_evaluation_templates_path, params: { evaluation_template: { name: "X", department_id: foreign_department.id, active: "1" } }
      }.not_to change(EvaluationTemplate, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects moving a template to another business's department on update" do
      patch admin_evaluation_template_path(template), params: { evaluation_template: { department_id: foreign_department.id } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(template.reload.department).to eq(department)
    end

    it "still accepts a department of the same business" do
      post admin_evaluation_templates_path, params: { evaluation_template: { name: "Own", department_id: department.id, active: "1" } }
      expect(response).to redirect_to(admin_evaluation_template_path(EvaluationTemplate.find_by!(name: "Own")))
    end
  end

  describe "performance reviews" do
    before { sign_in api_user_with(business, :view_monthly_reviews, :manage_reviews) }

    def create_review(**attributes)
      post performance_reviews_path, params: { performance_review: { review_year: 2026, review_month: 5 }.merge(attributes) }
    end

    it "rejects another business's employee (422, nothing saved)" do
      expect { create_review(employee_id: foreign_employee.id, department_id: department.id) }.not_to change(PerformanceReview, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects another business's department" do
      expect { create_review(employee_id: employee.id, department_id: foreign_department.id) }.not_to change(PerformanceReview, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a score on another business's criterion" do
      expect {
        create_review(employee_id: employee.id, department_id: department.id,
                      performance_review_scores_attributes: { "0" => { evaluation_criterion_id: foreign_criterion.id, score: 4 } })
      }.not_to change(PerformanceReview, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "still creates a review for a same-business employee, department and criterion" do
      expect {
        create_review(employee_id: employee.id, department_id: department.id,
                      performance_review_scores_attributes: { "0" => { evaluation_criterion_id: criterion.id, score: 4 } })
      }.to change(PerformanceReview, :count).by(1)
      expect(response).to redirect_to(performance_review_path(PerformanceReview.last))
    end
  end

  describe "performance observations" do
    before { sign_in api_user_with(business, :view_notes, :create_observations) }

    def create_observation(**attributes)
      post performance_observations_path,
           params: { performance_observation: { observation_date: Date.current, observation_type: "positive" }.merge(attributes) }
    end

    it "rejects another business's employee (422, nothing saved)" do
      expect { create_observation(employee_id: foreign_employee.id, evaluation_criterion_id: foreign_criterion.id) }
        .not_to change(PerformanceObservation, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects another business's criterion for a same-business employee" do
      expect { create_observation(employee_id: employee.id, evaluation_criterion_id: foreign_criterion.id) }
        .not_to change(PerformanceObservation, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "still records an observation for a same-business employee and criterion" do
      expect { create_observation(employee_id: employee.id, evaluation_criterion_id: criterion.id) }
        .to change(PerformanceObservation, :count).by(1)
      expect(response).to redirect_to(performance_observations_path)
    end
  end

  describe "model level (any write path)", type: :model do
    it "flags each foreign reference as :invalid" do
      expect(EvaluationTemplate.new(business: business, department: foreign_department, name: "T").tap(&:valid?)
               .errors.details[:department]).to include(a_hash_including(error: :invalid))

      review = PerformanceReview.new(business: business, department: foreign_department, employee: foreign_employee,
                                     reviewer: create(:user, business: other), review_year: 2026, review_month: 5)
      review.valid?
      %i[employee department reviewer].each do |attribute|
        expect(review.errors.details[attribute]).to include(a_hash_including(error: :invalid))
      end

      observation = PerformanceObservation.new(business: business, employee: foreign_employee, observed_by: create(:user, business: other),
                                               evaluation_criterion: foreign_criterion, observation_date: Date.current,
                                               observation_type: "positive")
      observation.valid?
      %i[employee observed_by evaluation_criterion].each do |attribute|
        expect(observation.errors.details[attribute]).to include(a_hash_including(error: :invalid))
      end
    end
  end
end
