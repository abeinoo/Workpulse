require "rails_helper"

# A1 / BUG-020: the admin dashboard (Reporting) lists staff, payroll periods and
# counts only within the viewer's authorization — the same policy scopes as
# admin/users#index (UserPolicy::Scope), payroll_periods#index
# (PayrollPeriodPolicy::Scope) and the requests list (EmployeeRequestPolicy::Scope).
# require_admin_access! admits branch-scopable permissions (view_employees,
# view_payroll, …), so the page itself must not widen what they may see.
RSpec.describe "Admin dashboard data scoping", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business, name: "Alpha Branch") }
  let(:branch_b) { create(:branch, business: business, name: "Beta Branch") }

  let!(:owner) { create(:user, :owner, business: business, first_name: "Olive", last_name: "Owner") }
  let!(:emp_a) { assigned_employee(branch_a, "Amal", "Alpha") }
  let!(:emp_b) { assigned_employee(branch_b, "Basil", "Beta") }

  # Legacy branch-tagged periods (new periods carry no branch; the dashboard
  # lists only branch-tagged ones). Distinct months: one period per business month.
  let!(:draft_b)     { create(:payroll_period, business: business, branch: branch_b, period_year: 2026, period_month: 3) }
  let!(:finalized_b) { period_with_entry(branch_b, emp_b, month: 2) }
  let!(:finalized_a) { period_with_entry(branch_a, emp_a, month: 1) }

  let!(:request_b) { create(:employee_request, business: business, user: emp_b) }

  let(:other_business) { create(:business) }
  let(:other_branch)   { create(:branch, business: other_business) }
  let!(:outsider) do
    create(:shift_assignment, business: other_business, branch: other_branch,
                              user: create(:user, business: other_business, first_name: "Omar", last_name: "Outside")).user
  end
  let!(:outside_period) do
    create(:payroll_period, :finalized, business: other_business, branch: other_branch, period_year: 2026, period_month: 2)
  end

  def assigned_employee(branch, first, last)
    user = create(:user, business: business, first_name: first, last_name: last)
    create(:shift_assignment, business: business, user: user, branch: branch)
    user
  end

  def period_with_entry(branch, employee, month:)
    period = create(:payroll_period, :finalized, business: business, branch: branch, period_year: 2026, period_month: month)
    create(:payroll_entry, payroll_period: period, user: employee)
    period
  end

  def role_user(permissions, scopes: {})
    role = create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes)
    create(:user, business: business, permission_role: role)
  end

  def branch_manager(scopes: {})
    manager = role_user(%w[view_employees view_attendance view_payroll view_requests], scopes: scopes)
    branch_a.update_column(:branch_manager_id, manager.id)
    manager
  end

  def dashboard_for(user)
    sign_in user
    get admin_root_path
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def employee_link?(doc, user) = doc.at_css("a[href='#{admin_user_path(user)}']").present?
  def period_link?(doc, period) = doc.at_css("a[href='#{payroll_period_path(period)}']").present?
  def stat(doc, index) = doc.css(".stat-card__value")[index].text.strip.to_i

  shared_examples "a branch-limited viewer" do
    it "lists only staff of the managed branch" do
      doc = dashboard_for(viewer)
      expect(employee_link?(doc, emp_a)).to be(true)
      expect(employee_link?(doc, emp_b)).to be(false)
      expect(employee_link?(doc, outsider)).to be(false)
    end

    it "lists no payroll period of another branch, draft or finalized" do
      doc = dashboard_for(viewer)
      expect(period_link?(doc, finalized_a)).to be(true)
      expect(period_link?(doc, finalized_b)).to be(false)
      expect(period_link?(doc, draft_b)).to be(false)
      expect(period_link?(doc, outside_period)).to be(false)
    end

    it "counts only staff and pending requests within scope" do
      doc = dashboard_for(viewer)
      expect(stat(doc, 0)).to eq(2) # the viewer and emp_a
      expect(stat(doc, 2)).to eq(0) # emp_b's pending request is out of scope
    end

    it "shows only employees the same viewer may see in the employee list" do
      doc = dashboard_for(viewer)
      shown = doc.css("a[href^='/admin/users/']").map { _1["href"] }.uniq
      get admin_users_path
      shown.each { |href| expect(response.body).to include(href) }
    end
  end

  context "a branch manager with the hierarchy default scope" do
    let(:viewer) { branch_manager }

    it_behaves_like "a branch-limited viewer"
  end

  context "a branch manager with an explicit branch scope" do
    let(:viewer) do
      branch_manager(scopes: { "view_employees" => "branch", "view_payroll" => "branch", "view_requests" => "branch" })
    end

    it_behaves_like "a branch-limited viewer"
  end

  context "a business-wide viewer without draft payroll access" do
    let(:viewer) do
      role_user(%w[view_employees view_payroll view_requests],
                scopes: { "view_employees" => "business", "view_payroll" => "business", "view_requests" => "business" })
    end

    it "keeps every branch's staff, finalized periods and counts, but no drafts" do
      doc = dashboard_for(viewer)
      expect(employee_link?(doc, emp_a)).to be(true)
      expect(employee_link?(doc, emp_b)).to be(true)
      expect(period_link?(doc, finalized_a)).to be(true)
      expect(period_link?(doc, finalized_b)).to be(true)
      expect(period_link?(doc, draft_b)).to be(false)
      expect(stat(doc, 2)).to eq(1)
      expect(employee_link?(doc, outsider)).to be(false)
      expect(period_link?(doc, outside_period)).to be(false)
    end
  end

  context "the owner" do
    it "sees the whole business, drafts included, and nothing of another business" do
      doc = dashboard_for(owner)
      expect(employee_link?(doc, emp_a)).to be(true)
      expect(employee_link?(doc, emp_b)).to be(true)
      [ draft_b, finalized_b, finalized_a ].each { |period| expect(period_link?(doc, period)).to be(true) }
      expect(stat(doc, 0)).to eq(2) # every employee except the owner
      expect(stat(doc, 1)).to eq(2)
      expect(stat(doc, 2)).to eq(1)
      expect(employee_link?(doc, outsider)).to be(false)
      expect(period_link?(doc, outside_period)).to be(false)
    end
  end

  context "a user admitted only by a non-scopable admin permission" do
    let(:viewer) { role_user(%w[manage_devices]) }

    it "still opens the page but sees no other employee, period or request" do
      doc = dashboard_for(viewer)
      expect(employee_link?(doc, emp_a)).to be(false)
      expect(employee_link?(doc, emp_b)).to be(false)
      [ draft_b, finalized_b, finalized_a ].each { |period| expect(period_link?(doc, period)).to be(false) }
      expect(stat(doc, 0)).to eq(1) # only the viewer
      expect(stat(doc, 2)).to eq(0)
    end
  end

  context "a user without any admin permission" do
    it "is redirected to the root, as before" do
      sign_in role_user(%w[view_requests])
      get admin_root_path
      expect(response).to redirect_to(root_path)
    end
  end
end
