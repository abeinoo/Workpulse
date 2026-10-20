require "rails_helper"

# Advance visibility (SEC-M2-7; decisions of 2026-10-19): one's own advances
# (the existing own-record rule), and another employee's advances only with
# view_payroll and the employee inside the view_payroll scope — configured, else
# the hierarchy default; never business-wide by default. Same rule for the
# collection and for a single record.
RSpec.describe "Advance view scope", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }

  let(:emp_a) { create(:user, business: business).tap { |u| assign(u, branch_a) } }
  let(:emp_b) { create(:user, business: business).tap { |u| assign(u, branch_b) } }

  let!(:advance_a) { create(:advance, business: business, user: emp_a) }
  let!(:advance_b) { create(:advance, business: business, user: emp_b) }
  let!(:foreign)   { create(:advance) }

  def assign(user, branch)
    create(:shift_assignment, business: business, user: user, branch: branch,
                              effective_from: 1.month.ago.to_date, effective_to: nil)
  end

  def role_user(*permissions, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                              permissions: permissions.map(&:to_s), permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def index_ids
    get "/api/v1/advances", as: :json
    expect(response).to have_http_status(:ok)
    api_data.map { |a| a["id"] }
  end

  def show_status(advance)
    get "/api/v1/advances/#{advance.id}", as: :json
    response.status
  end

  it "shows a branch manager with view_payroll only their branch's advances (index and record)" do
    manager = role_user(:view_payroll).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }
    sign_in manager

    expect(index_ids).to contain_exactly(advance_a.id)
    expect(show_status(advance_a)).to eq(200)
    expect(show_status(advance_b)).to eq(404)
  end

  it "follows an area manager's area-managed branches" do
    sign_in role_user(:view_payroll).tap { |u| branch_b.update_column(:area_manager_id, u.id) }

    expect(index_ids).to contain_exactly(advance_b.id)
    expect(show_status(advance_a)).to eq(404)
  end

  it "does not give view_payroll without a configured scope or managed branch the business's advances" do
    viewer     = role_user(:view_payroll)
    own        = create(:advance, business: business, user: viewer)
    sign_in viewer

    expect(index_ids).to contain_exactly(own.id)
    expect(show_status(advance_a)).to eq(404)
  end

  it "denies another employee's advances without view_payroll" do
    viewer = role_user(:view_employees, scopes: { "view_employees" => "business" })
    sign_in viewer

    expect(index_ids).to be_empty
    expect(show_status(advance_a)).to eq(404)
  end

  it "keeps one's own advances visible without view_payroll" do
    sign_in emp_a
    expect(index_ids).to contain_exactly(advance_a.id)
  end

  it "follows a configured business-wide scope, never another business" do
    sign_in role_user(:view_payroll, scopes: { "view_payroll" => "business" })

    expect(index_ids).to contain_exactly(advance_a.id, advance_b.id)
    expect(show_status(foreign)).to eq(404)
  end
end
