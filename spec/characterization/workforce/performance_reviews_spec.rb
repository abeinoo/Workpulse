require "rails_helper"

# Characterization (Pilot 3, M1 groups 1–2) — CURRENT performance review
# lifecycle and visibility. Cross-business reference rejection (SEC-P3-1) is in
# spec/requests/security/performance_cross_business_spec.rb; analytics/exports
# in spec/requests/performance/* and spec/services/performance/*.
RSpec.describe "Characterization: performance reviews", type: :request do
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let(:department) { create(:department, business: business) }
  let(:employee)   { create(:user, business: business, department: department) }
  let(:manager)    { api_user_with(business, :view_monthly_reviews, :manage_reviews, scopes: { "view_monthly_reviews" => "business" }) }
  let(:finalizer)  { api_user_with(business, :view_monthly_reviews, :manage_reviews, :finalize_reviews, scopes: { "view_monthly_reviews" => "business" }) }

  def review(status: "draft", month: 1, for_employee: employee)
    create(:performance_review, business: business, department: department, employee: for_employee,
                                reviewer: owner, review_year: 2026, review_month: month, status: status)
  end

  describe "lifecycle" do
    it "creates a draft review in the actor's business, with the actor as reviewer" do
      sign_in manager
      post performance_reviews_path, params: { performance_review: { employee_id: employee.id, review_year: 2026, review_month: 4 } }
      created = PerformanceReview.last
      expect(response).to redirect_to(performance_review_path(created))
      expect(created).to have_attributes(status: "draft", business_id: business.id, reviewer_id: manager.id, department_id: department.id)
    end

    it "rejects an invalid period with 422" do
      sign_in manager
      expect {
        post performance_reviews_path, params: { performance_review: { employee_id: employee.id, review_year: 2026, review_month: 13 } }
      }.not_to change(PerformanceReview, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "allows a second review for the same employee and period (no uniqueness rule — existing behaviour)" do
      review(month: 4)
      sign_in manager
      expect {
        post performance_reviews_path, params: { performance_review: { employee_id: employee.id, review_year: 2026, review_month: 4 } }
      }.to change(PerformanceReview, :count).by(1)
    end

    it "manage_reviews can edit and submit a draft, but not finalize it" do
      draft = review
      sign_in manager
      patch performance_review_path(draft), params: { performance_review: { notes: "Updated" } }
      expect(draft.reload.notes).to eq("Updated")
      sign_in manager
      patch submit_performance_review_path(draft)
      expect(draft.reload.status).to eq("submitted")
      sign_in manager
      patch finalize_performance_review_path(draft)
      expect(response).to redirect_to(root_path)
      expect(draft.reload.status).to eq("submitted")
    end

    it "finalize_reviews can finalize a draft directly (no submit step required — existing behaviour)" do
      draft = review
      sign_in finalizer
      patch finalize_performance_review_path(draft)
      expect(response).to redirect_to(performance_review_path(draft))
      expect(draft.reload).to have_attributes(status: "finalized")
      expect(draft.finalized_at).to be_present
    end

    it "a finalized review can no longer be edited, submitted, finalized again or deleted" do
      finalized = review(status: "finalized")
      sign_in finalizer
      patch performance_review_path(finalized), params: { performance_review: { notes: "Changed" } }
      expect(response).to redirect_to(root_path)
      expect(finalized.reload.notes).not_to eq("Changed")
      sign_in finalizer
      patch submit_performance_review_path(finalized)
      expect(finalized.reload.status).to eq("finalized")
      sign_in finalizer
      delete performance_review_path(finalized)
      expect(PerformanceReview.exists?(finalized.id)).to be(true)
    end

    it "manage_reviews can delete a draft" do
      draft = review
      sign_in manager
      delete performance_review_path(draft)
      expect(response).to redirect_to(performance_reviews_path)
      expect(PerformanceReview.exists?(draft.id)).to be(false)
    end

    it "stores the average of the entered scores" do
      template  = EvaluationTemplate.create!(business: business, department: department, name: "Template")
      criteria  = [ EvaluationCriterion.create!(evaluation_template: template, name: "A"),
                    EvaluationCriterion.create!(evaluation_template: template, name: "B") ]
      sign_in manager
      post performance_reviews_path, params: { performance_review: {
        employee_id: employee.id, review_year: 2026, review_month: 6,
        performance_review_scores_attributes: { "0" => { evaluation_criterion_id: criteria[0].id, score: 3 },
                                                "1" => { evaluation_criterion_id: criteria[1].id, score: 4 } }
      } }
      expect(PerformanceReview.last.average_score).to eq(3.5)
    end
  end

  describe "visibility" do
    let(:branch_a) { create(:branch, business: business) }
    let(:branch_b) { create(:branch, business: business) }
    let(:shift)    { create(:shift, :fixed_time, business: business) }
    let(:emp_a)    { create(:user, business: business, department: department) }
    let(:emp_b)    { create(:user, business: business, department: department) }

    before do
      create(:shift_assignment, user: emp_a, branch: branch_a, shift: shift)
      create(:shift_assignment, user: emp_b, branch: branch_b, shift: create(:shift, :fixed_time, business: business))
    end

    def visible_to(user) = PerformanceReviewPolicy::Scope.new(user, PerformanceReview).resolve

    it "business-scoped reviewers and the owner see every review of the business, never another business's" do
      reviews = [ review(for_employee: emp_a), review(for_employee: emp_b, status: "finalized", month: 2) ]
      foreign = create(:performance_review)
      expect(visible_to(manager)).to match_array(reviews)
      expect(visible_to(owner)).to match_array(reviews)
      expect(visible_to(owner)).not_to include(foreign)
    end

    it "a branch-scoped reviewer sees only reviews of employees in their managed branch" do
      in_a = review(for_employee: emp_a); in_b = review(for_employee: emp_b, month: 2)
      branch_reviewer = api_user_with(business, :view_monthly_reviews, scopes: { "view_monthly_reviews" => "branch" })
      branch_a.update!(branch_manager: branch_reviewer)
      expect(visible_to(branch_reviewer)).to contain_exactly(in_a)
      expect(visible_to(branch_reviewer)).not_to include(in_b)
    end

    it "an employee without review permissions sees only their own finalized reviews" do
      own_final = review(for_employee: emp_a, status: "finalized")
      own_draft = review(for_employee: emp_a, month: 2)
      others    = review(for_employee: emp_b, status: "finalized", month: 3)
      expect(visible_to(emp_a)).to contain_exactly(own_final)

      sign_in emp_a
      get performance_review_path(own_final)
      expect(response).to have_http_status(:ok)
      [ own_draft, others ].each do |hidden|
        sign_in emp_a
        get performance_review_path(hidden)
        expect(response).to have_http_status(:not_found)
      end
    end

    it "another business's review is 404 even for the owner" do
      sign_in owner
      get performance_review_path(create(:performance_review))
      expect(response).to have_http_status(:not_found)
    end
  end
end
