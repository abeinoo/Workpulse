require "rails_helper"

RSpec.describe "Admin job titles", type: :request do
  let(:business) { create(:business) }
  let(:admin)    { edr_user_with(:view_employees, :manage_employees, business: business) }

  before { sign_in admin }

  it "lists, creates and deactivates job titles for the business" do
    post admin_job_titles_path, params: { job_title: { name: "  مصفف   شعر ", active: "1" } }
    expect(response).to redirect_to(admin_job_titles_path)
    title = JobTitle.find_by!(business: business)
    expect(title.name).to eq("مصفف شعر")

    patch admin_job_title_path(title), params: { job_title: { active: "0" } }
    expect(title.reload).not_to be_active
    expect(JobTitle.options_for(business)).to be_empty
    expect(JobTitle.options_for(business, current: "مصفف شعر")).to eq([ "مصفف شعر" ])

    get admin_job_titles_path
    expect(response.body).to include("مصفف شعر")
  end

  it "rejects case-insensitive duplicates" do
    create(:job_title, business: business, name: "Reception")
    post admin_job_titles_path, params: { job_title: { name: "reception", active: "1" } }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "is not available to users who can't manage employees or settings" do
    sign_in edr_user_with(:view_employees, business: business)
    get admin_job_titles_path
    expect(response).to redirect_to(root_path)
  end

  it "doesn't expose another business's titles" do
    other = create(:job_title, business: create(:business))
    get edit_admin_job_title_path(other)
    expect(response).to have_http_status(:not_found)
  end
end
