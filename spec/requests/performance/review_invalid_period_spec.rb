require "rails_helper"

# PERF-D1 regression: an invalid review period re-renders the form with
# validation errors instead of raising Date::Error while composing the
# month's observations.
RSpec.describe "Performance review with an invalid period", type: :request do
  let(:business)   { create(:business) }
  let(:department) { create(:department, business: business) }
  let(:employee)   { create(:user, business: business, department: department) }
  let(:manager) do
    api_user_with(business, :view_monthly_reviews, :manage_reviews, scopes: { "view_monthly_reviews" => "business" })
  end

  before do
    template = EvaluationTemplate.create!(business: business, department: department, name: "Template")
    EvaluationCriterion.create!(evaluation_template: template, name: "Punctuality")
    sign_in manager
  end

  def submit(month)
    post performance_reviews_path, params: { performance_review: { employee_id: employee.id, review_year: 2026, review_month: month } }
  end

  it "returns the normal 422 validation response for month 13, persists nothing, and shows the error" do
    expect { submit(13) }.not_to change(PerformanceReview, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(CGI.escapeHTML(PerformanceReview.new.errors.generate_message(:review_month, :inclusion)))
  end

  it "still creates a review for a valid month" do
    expect { submit(6) }.to change(PerformanceReview, :count).by(1)
    expect(response).to redirect_to(performance_review_path(PerformanceReview.last))
  end
end
