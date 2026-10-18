require "rails_helper"

RSpec.describe "Performance reviews index analytics", type: :request do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :owner, business: business) }
  let(:department) { create(:department, business: business) }
  let(:employee)   { create(:user, business: business, department: department) }

  before do
    review = create(:performance_review, business: business, department: department,
      employee: employee, reviewer: owner, review_year: 2026, review_month: 1, status: "finalized")
    review.update_column(:average_score, 4)

    sign_in owner
  end

  it "renders the analytics panel with no filters" do
    get performance_reviews_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("performance.reviews.analytics.title"))
  end

  it "renders when filters narrow to a single employee" do
    get performance_reviews_path(employee_id: employee.id, status: "finalized",
      from_date: "2026-01-01", to_date: "2026-01-31")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(html_escaped(I18n.t("performance.reviews.analytics.employee_summary_title", name: employee.full_name)))
  end

  it "renders when a branch filter matches nothing" do
    branch = create(:branch, business: business)

    get performance_reviews_path(branch_id: branch.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("performance.reviews.empty"))
  end
end
