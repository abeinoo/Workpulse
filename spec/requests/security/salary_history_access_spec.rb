require "rails_helper"

# Salary history on the employee page (view_salary_history):
# * the recorded business owner sees every stored profile of another employee;
#   anyone else only with view_salary_history, and only for employees inside both
#   the view_payroll and the view_salary_history scope;
# * view_payroll and manage_salary_profiles alone never show history, and nobody
#   sees their own history;
# * labels come from the effective date (Scheduled / Current / Previous), never
#   from the stored `active` flag;
# * every listed profile is audited (source admin_employee_page_history);
# * history grants no editing, and the API stays current-only.
RSpec.describe "Salary history access", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  let(:emp_a) { create(:user, business: business).tap { |u| assign(u, branch_a) } }
  let(:emp_b) { create(:user, business: business).tap { |u| assign(u, branch_b) } }

  # Entered in date order, so the scheduled raise holds the stored `active` flag
  # while the current profile does not.
  let!(:a_profiles) { salary_history_for(emp_a) }
  let!(:b_profiles) { salary_history_for(emp_b) }

  def assign(user, branch)
    create(:shift_assignment, business: business, user: user, branch: branch,
                              effective_from: 1.month.ago.to_date, effective_to: nil)
  end

  def salary_history_for(user)
    previous  = create(:salary_profile, user: user, base_amount: 1111.11, effective_from: 2.years.ago.to_date)
    current   = create(:salary_profile, user: user, base_amount: 2222.22, effective_from: 1.year.ago.to_date)
    scheduled = create(:salary_profile, user: user, base_amount: 3333.33, effective_from: 1.month.from_now.to_date)
    { previous: previous.reload, current: current.reload, scheduled: scheduled.reload }
  end

  def role_user(*permissions, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                              permissions: permissions.map(&:to_s), permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def branch_manager_of(branch, *permissions, scopes: {})
    role_user(*permissions, scopes: scopes).tap { |u| branch.update_column(:branch_manager_id, u.id) }
  end

  def history_viewer = branch_manager_of(branch_a, :view_employees, :view_payroll, :view_salary_history)

  def salary_views   = AuditLog.where(action: "view_salary")
  def history_views  = salary_views.where("metadata->>'source' = ?", "admin_employee_page_history")

  # [status, base salary] per history row, in page order.
  def history_rows
    Nokogiri::HTML(response.body).css("tr[data-salary-history-status]").map do |tr|
      [ tr["data-salary-history-status"], tr.css("td")[1].text.strip ]
    end
  end

  def expect_full_history
    expect(response).to have_http_status(:ok)
    rows = history_rows
    expect(rows.map(&:first)).to eq(%w[scheduled current previous])
    expect(rows.map(&:last).join(" ")).to include("3,333.33", "2,222.22", "1,111.11")
    expect(response.body).to include(I18n.t("salary_profiles.statuses.scheduled"),
                                     I18n.t("salary_profiles.statuses.current"),
                                     I18n.t("salary_profiles.statuses.previous"))
  end

  def expect_current_only
    expect(response).to have_http_status(:ok)
    expect(history_rows).to be_empty
    expect(response.body).not_to include("1,111.11", "3,333.33")
  end

  describe "the recorded business owner" do
    it "sees every profile, newest first, labelled by effective date" do
      sign_in owner
      get admin_user_path(emp_b)
      expect_full_history
    end

    it "is the business's owner_id, not a role" do
      expect(business.reload.owner_id).to eq(owner.id)
      expect(owner.permission_role).to be_nil
    end
  end

  describe "a user granted view_salary_history" do
    it "sees the history of an employee in their hierarchy scope" do
      sign_in history_viewer
      get admin_user_path(emp_a)
      expect_full_history
    end

    it "sees the history business-wide when both scopes are business" do
      sign_in role_user(:view_employees, :view_payroll, :view_salary_history,
                        scopes: { "view_employees" => "business", "view_payroll" => "business",
                                  "view_salary_history" => "business" })
      get admin_user_path(emp_b)
      expect_full_history
    end

    it "sees no history (and no salary) for an employee outside their scope" do
      sign_in history_viewer
      expect { get admin_user_path(emp_b) }.not_to change(history_views, :count)
      expect(history_rows).to be_empty
      expect(response.body).not_to include("1,111.11", "2,222.22", "3,333.33")
    end

    it "is limited by the view_salary_history scope even when view_payroll is business-wide" do
      sign_in branch_manager_of(branch_a, :view_employees, :view_payroll, :view_salary_history,
                                scopes: { "view_employees" => "business", "view_payroll" => "business",
                                          "view_salary_history" => "branch" })
      get admin_user_path(emp_b)
      expect_current_only
      expect(response.body).to include("2,222.22")

      get admin_user_path(emp_a)
      expect_full_history
    end

    it "is limited by the view_payroll scope even when view_salary_history is business-wide" do
      sign_in branch_manager_of(branch_a, :view_employees, :view_payroll, :view_salary_history,
                                scopes: { "view_employees" => "business", "view_payroll" => "branch",
                                          "view_salary_history" => "business" })
      get admin_user_path(emp_b)
      expect(history_rows).to be_empty
      expect(response.body).not_to include("1,111.11", "2,222.22", "3,333.33")
    end

    it "never sees another business's employee" do
      other = create(:user, business: create(:business))
      create(:salary_profile, user: other, base_amount: 9876.54, effective_from: 1.year.ago.to_date)
      sign_in role_user(:view_employees, :view_payroll, :view_salary_history,
                        scopes: { "view_employees" => "business", "view_payroll" => "business",
                                  "view_salary_history" => "business" })

      expect { get admin_user_path(other) }.not_to change(salary_views, :count)
      # A 404 (the test-env exception page echoes spec source, so the body is not checked).
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "without view_salary_history" do
    it "view_payroll shows the current profile only" do
      sign_in branch_manager_of(branch_a, :view_employees, :view_payroll)
      expect { get admin_user_path(emp_a) }.not_to change(history_views, :count)
      expect_current_only
      expect(response.body).to include("2,222.22")
    end

    it "manage_salary_profiles (with view_payroll) does not add history" do
      sign_in branch_manager_of(branch_a, :view_employees, :view_payroll, :manage_salary_profiles)
      get admin_user_path(emp_a)
      expect_current_only
    end

    it "manage_salary_profiles alone shows no amounts and no history" do
      sign_in branch_manager_of(branch_a, :view_employees, :manage_salary_profiles)
      get admin_user_path(emp_a)
      expect(history_rows).to be_empty
      expect(response.body).not_to include("1,111.11", "2,222.22", "3,333.33")
    end
  end

  describe "one's own page" do
    it "shows a view_salary_history holder only their own current profile" do
      viewer = history_viewer
      own = salary_history_for(viewer)
      sign_in viewer

      expect { get admin_user_path(viewer) }.not_to change(history_views, :count)
      expect_current_only
      expect(response.body).to include("2,222.22")
      expect(salary_views.last.metadata["salary_profile_ids"]).to eq([ own[:current].id ])
    end

    it "shows the owner only their own current profile" do
      salary_history_for(owner)
      sign_in owner
      get admin_user_path(owner)
      expect_current_only
    end
  end

  describe "status labels" do
    it "come from the effective date, not the stored active flag" do
      expect(a_profiles[:scheduled]).to be_active
      expect(a_profiles[:current]).not_to be_active

      sign_in history_viewer
      get admin_user_path(emp_a)
      expect(history_rows).to match([
        [ "scheduled", a_string_including("3,333.33") ],
        [ "current",   a_string_including("2,222.22") ],
        [ "previous",  a_string_including("1,111.11") ]
      ])
    end

    it "label a profile Current from its effective date onward" do
      sign_in history_viewer
      travel_to(a_profiles[:scheduled].effective_from.in_time_zone(business.timezone) + 12.hours) do
        get admin_user_path(emp_a)
      end
      expect(history_rows.map(&:first)).to eq(%w[current previous previous])
    end
  end

  describe "audit" do
    it "records the current view and every listed history profile, once each, without amounts" do
      viewer = history_viewer
      sign_in viewer

      expect { get admin_user_path(emp_a) }.to change(salary_views, :count).by(2)

      log = history_views.sole
      expect(log).to have_attributes(actor_id: viewer.id, auditable: emp_a, business_id: business.id)
      expect(log.metadata).to eq("source" => "admin_employee_page_history", "self_view" => false,
                                 "salary_profile_ids" => a_profiles.values_at(:scheduled, :current, :previous).map(&:id))
      expect(log.to_json).not_to include("1111.11", "2222.22", "3333.33")

      current_log = salary_views.where("metadata->>'source' = ?", "admin_employee_page").sole
      expect(current_log.metadata["salary_profile_ids"]).to eq([ a_profiles[:current].id ])
    end
  end

  describe "editing" do
    it "history grants no edit action or update" do
      sign_in history_viewer
      get admin_user_path(emp_a)
      a_profiles.each_value do |profile|
        expect(response.body).not_to include(edit_admin_user_salary_profile_path(emp_a, profile))
      end

      patch admin_user_salary_profile_path(emp_a, a_profiles[:previous]),
            params: { salary_profile: { base_amount: "9999" } }
      expect(a_profiles[:previous].reload.base_amount).to eq(1111.11)
    end

    it "keeps the edit action on the current card only, for a manager, never in the history rows" do
      SalaryProfile.where(id: a_profiles[:scheduled].id).delete_all
      a_profiles[:current].update_column(:active, true)
      sign_in branch_manager_of(branch_a, :view_employees, :view_payroll, :manage_salary_profiles, :view_salary_history)

      get admin_user_path(emp_a)
      expect(history_rows.map(&:first)).to eq(%w[current previous])
      expect(response.body.scan(edit_admin_user_salary_profile_path(emp_a, a_profiles[:current])).size).to eq(1)
      expect(response.body).not_to include(edit_admin_user_salary_profile_path(emp_a, a_profiles[:previous]))
      Nokogiri::HTML(response.body).css("tr[data-salary-history-status] a").each do |link|
        expect(link["href"]).not_to include("salary_profiles")
      end
    end
  end

  describe "the API (unchanged: current profile only)" do
    def api_data = JSON.parse(response.body)["data"]

    it "returns only the current profile to a view_salary_history holder" do
      sign_in history_viewer
      get "/api/v1/users/#{emp_a.id}/salary_profiles", as: :json
      expect(api_data.map { _1["id"] }).to eq([ a_profiles[:current].id ])

      %i[previous scheduled].each do |key|
        get "/api/v1/users/#{emp_a.id}/salary_profiles/#{a_profiles[key].id}", as: :json
        expect(response).to have_http_status(:not_found)
      end
    end

    it "returns only the current profile to the owner" do
      sign_in owner
      get "/api/v1/users/#{emp_a.id}/salary_profiles", as: :json
      expect(api_data.map { _1["id"] }).to eq([ a_profiles[:current].id ])
    end
  end

  describe "the permission" do
    it "requires view_payroll" do
      expect(PermissionRole.new(business: business, name: "H", permissions: %w[view_salary_history])).not_to be_valid
      expect(PermissionRole::PERMISSION_DEPENDENCIES["view_salary_history"]).to eq(%w[view_payroll])
    end

    it "is scopable and in no default role" do
      expect(PermissionRole::SCOPABLE_PERMISSIONS).to include("view_salary_history")
      PermissionRole::DEFAULT_PERMISSIONS_BY_ROLE_TYPE.each_value do |permissions|
        expect(permissions).not_to include("view_salary_history")
      end
    end
  end
end
