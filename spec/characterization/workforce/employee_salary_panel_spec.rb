require "rails_helper"

# Characterization (SAL M1) — the salary card of the employee page
# (Admin::UsersController#show + app/views/admin/users/show.html.erb), recorded from
# the unchanged code before the card becomes an Attendance & Payroll-contributed
# panel (module-boundaries.md §12.1 UI composition;
# docs/architecture/workforce-employee-salary-panel-baseline-failures.txt).
#
# Pins, per visibility case: whether the card renders, its markup (golden files,
# whitespace between tags collapsed, record ids replaced by placeholders — never
# re-record to absorb a difference), and the exact salary-view audits.
# Golden files were written once from the unchanged code with RECORD_SAL_GOLDEN=1.
RSpec.describe "Characterization: employee-page salary panel (SAL M1)", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business).tap { |u| assign(u, branch_a) } }
  let!(:history) do
    { old: create(:salary_profile, user: employee, base_amount: 1234.56, effective_from: 2.years.ago.to_date),
      current: create(:salary_profile, user: employee, base_amount: 4321.98, effective_from: 1.year.ago.to_date) }
  end

  GOLDEN_DIR = Rails.root.join("spec/fixtures/files/employee_salary_panel")

  def assign(user, branch)
    create(:shift_assignment, business: business, user: user, branch: branch,
                              effective_from: 1.month.ago.to_date, effective_to: nil)
  end

  def role_user(*permissions, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                              permissions: permissions.map(&:to_s), permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def branch_manager(*permissions)
    role_user(*permissions).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }
  end

  def salary_views = AuditLog.where(action: "view_salary")

  def salary_card(page_user)
    title = I18n.t("admin.users.salary_profile")
    card = Nokogiri::HTML(response.body).css(".card").find { |c| c.at_css("h2.card-title")&.text&.strip == title }
    return nil unless card

    html = card.to_html.gsub(/>\s+</, "><").gsub(/\s+/, " ").strip
    ids = { "EMPLOYEE" => page_user.id }
    ids["PROFILE"] = history[:current].id if page_user == employee
    ids.reduce(html) { |out, (name, id)| out.gsub(%r{/#{id}(?=[/"?])}, "/#{name}") }
  end

  def expect_golden(name, html)
    path = GOLDEN_DIR.join("#{name}.html")
    if ENV["RECORD_SAL_GOLDEN"]
      FileUtils.mkdir_p(GOLDEN_DIR)
      File.write(path, "#{html}\n")
    end
    expect(html).to eq(File.read(path).chomp)
  end

  it "no card and no audit without view_payroll or manage_salary_profiles" do
    sign_in role_user(:view_employees, scopes: { "view_employees" => "business" })
    expect { get admin_user_path(employee) }.not_to change(salary_views, :count)
    expect(response).to have_http_status(:ok)
    expect(salary_card(employee)).to be_nil
  end

  it "view only (in-scope payroll viewer): the current profile, no actions, one audit" do
    viewer = branch_manager(:view_employees, :view_payroll)
    sign_in viewer
    expect { get admin_user_path(employee) }.to change(salary_views, :count).by(1)
    expect(salary_views.last).to have_attributes(actor_id: viewer.id, auditable: employee)
    expect(salary_views.last.metadata).to eq("source" => "admin_employee_page", "self_view" => false,
                                             "salary_profile_ids" => [ history[:current].id ])
    expect_golden("view_only", salary_card(employee))
  end

  it "view and manage: the current profile with the new-profile and edit actions, one audit" do
    sign_in branch_manager(:view_employees, :view_payroll, :manage_salary_profiles)
    expect { get admin_user_path(employee) }.to change(salary_views, :count).by(1)
    expect_golden("view_and_manage", salary_card(employee))
  end

  it "view, employee without a profile: the no-active-profile text, no audit" do
    SalaryProfile.where(user: employee).delete_all
    sign_in branch_manager(:view_employees, :view_payroll, :manage_salary_profiles)
    expect { get admin_user_path(employee) }.not_to change(salary_views, :count)
    expect_golden("no_profile", salary_card(employee))
  end

  it "manage only (no view_payroll): the card with the new-profile action, no amounts, no audit" do
    manager = branch_manager(:view_employees, :manage_salary_profiles)
    sign_in manager
    expect { get admin_user_path(employee) }.not_to change(salary_views, :count)
    card = salary_card(employee)
    expect(card).not_to include("4,321.98")
    expect_golden("manage_only", card)
  end

  it "own page: the employee's own current salary, a self-view audit" do
    manager = branch_manager(:view_employees, :view_payroll)
    own = create(:salary_profile, user: manager, base_amount: 777.5, effective_from: 1.year.ago.to_date)
    sign_in manager
    expect { get admin_user_path(manager) }.to change(salary_views, :count).by(1)
    expect(salary_views.last.metadata).to eq("source" => "admin_employee_page", "self_view" => true,
                                             "salary_profile_ids" => [ own.id ])
    expect_golden("own_page", salary_card(manager).gsub(%r{/#{own.id}(?=[/"?])}, "/PROFILE"))
  end
end
