require "rails_helper"

# Salary-profile access (SEC-M2-5, SEC-M2-6, SEC-M2-7, AP-D1; decisions of 2026-10-19):
# * an employee sees only their own CURRENT salary — never the history — with or
#   without view_payroll and whatever their own data scope;
# * another employee's salary needs view_payroll and the employee inside the
#   view_payroll scope (configured, else the hierarchy default — never business-wide);
# * nobody creates or changes their own salary profile;
# * every successful salary view is audited ("view_salary"), without amounts.
RSpec.describe "Salary profile access", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  let(:emp_a) { create(:user, business: business).tap { |u| assign(u, branch_a) } }
  let(:emp_b) { create(:user, business: business).tap { |u| assign(u, branch_b) } }

  # Historical 1,234.56, current 4,321.98.
  let!(:a_profiles) { salary_history_for(emp_a) }
  let!(:b_profiles) { salary_history_for(emp_b) }

  def assign(user, branch)
    create(:shift_assignment, business: business, user: user, branch: branch,
                              effective_from: 1.month.ago.to_date, effective_to: nil)
  end

  def salary_history_for(user)
    historical = create(:salary_profile, user: user, base_amount: 1234.56, effective_from: 2.years.ago.to_date)
    current    = create(:salary_profile, user: user, base_amount: 4321.98, effective_from: 1.year.ago.to_date)
    { historical: historical.reload, current: current }
  end

  def role_user(*permissions, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                              permissions: permissions.map(&:to_s), permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def branch_manager_of(branch, *permissions, scopes: {})
    role_user(*permissions, scopes: scopes).tap { |u| branch.update_column(:branch_manager_id, u.id) }
  end

  def area_manager_of(branch, *permissions, scopes: {})
    role_user(*permissions, scopes: scopes).tap { |u| branch.update_column(:area_manager_id, u.id) }
  end

  def api_index(user) = get("/api/v1/users/#{user.id}/salary_profiles", as: :json)
  def api_show(user, profile) = get("/api/v1/users/#{user.id}/salary_profiles/#{profile.id}", as: :json)
  def returned_ids = api_data.map { |p| p["id"] }
  def salary_views = AuditLog.where(action: "view_salary")

  describe "an employee's own salary (API)" do
    it "returns only the current profile, without view_payroll, and does not raise (AP-D1)" do
      sign_in emp_a
      api_index(emp_a)

      expect(response).to have_http_status(:ok)
      expect(returned_ids).to eq([ a_profiles[:current].id ])
      expect(response.body).not_to include("1234.56")
    end

    it "does not return their own historical profile by id" do
      sign_in emp_a
      api_show(emp_a, a_profiles[:historical])
      expect(response).to have_http_status(:not_found)

      api_show(emp_a, a_profiles[:current])
      expect(response).to have_http_status(:ok)
    end

    it "is visible even when the configured data scope excludes them" do
      employee = role_user(:view_payroll, scopes: { "view_payroll" => "branch" })
      current  = salary_history_for(employee)[:current]
      sign_in employee
      api_index(employee)

      expect(response).to have_http_status(:ok)
      expect(returned_ids).to eq([ current.id ])
    end

    it "shows a payroll viewer only their own current profile, not their own history" do
      manager = branch_manager_of(branch_a, :view_employees, :view_payroll)
      own     = salary_history_for(manager)
      sign_in manager
      api_index(manager)

      expect(returned_ids).to eq([ own[:current].id ])
    end
  end

  describe "another employee's salary (API)" do
    it "is not found for a plain employee" do
      sign_in emp_b
      api_index(emp_a)
      expect(response).to have_http_status(:not_found)
    end

    it "returns nothing without view_payroll, even when the employee is visible" do
      sign_in role_user(:view_employees, scopes: { "view_employees" => "business" })
      api_index(emp_a)

      expect(response).to have_http_status(:ok)
      expect(api_data).to eq([])
      expect(response.body).not_to include("4321.98")
    end

    it "is visible to a branch manager with view_payroll for an employee of their branch — current profile only" do
      sign_in branch_manager_of(branch_a, :view_employees, :view_payroll)
      api_index(emp_a)

      expect(returned_ids).to eq([ a_profiles[:current].id ])
      expect(response.body).not_to include("1234.56")
    end

    it "does not disclose that employee's historical profile by guessed id" do
      sign_in branch_manager_of(branch_a, :view_employees, :view_payroll)
      expect { api_show(emp_a, a_profiles[:historical]) }.not_to change(salary_views, :count)

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("1234.56")
    end

    it "is hidden from that manager for an employee of another branch (index and guessed id)" do
      sign_in branch_manager_of(branch_a, :view_employees, :view_payroll, scopes: { "view_employees" => "business" })
      api_index(emp_b)
      expect(api_data).to eq([])

      api_show(emp_b, b_profiles[:current])
      expect(response).to have_http_status(:not_found)
    end

    it "follows the area manager's area-managed branches" do
      sign_in area_manager_of(branch_b, :view_employees, :view_payroll, scopes: { "view_employees" => "business" })
      api_index(emp_b)
      expect(returned_ids).to include(b_profiles[:current].id)

      api_index(emp_a)
      expect(api_data).to eq([])
    end

    it "is not business-wide for view_payroll without a configured scope or managed branch" do
      sign_in role_user(:view_employees, :view_payroll, scopes: { "view_employees" => "business" })
      api_index(emp_a)
      expect(api_data).to eq([])
    end

    it "follows a configured business-wide view_payroll scope" do
      sign_in role_user(:view_employees, :view_payroll,
                        scopes: { "view_employees" => "business", "view_payroll" => "business" })
      api_index(emp_b)
      expect(returned_ids).to include(b_profiles[:current].id)
    end

    it "is business-wide for the owner — current profile only, never history" do
      sign_in owner
      api_index(emp_b)
      expect(returned_ids).to eq([ b_profiles[:current].id ])

      api_show(emp_b, b_profiles[:historical])
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("1234.56")
    end

    it "keeps the historical profiles stored" do
      sign_in owner
      api_index(emp_b)
      expect(emp_b.salary_profiles.count).to eq(2)
    end
  end

  describe "the employee page (HTML)" do
    it "shows no salary to a user who may see the employee but lacks view_payroll" do
      sign_in role_user(:view_employees, scopes: { "view_employees" => "business" })
      get admin_user_path(emp_a)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("4,321.98")
      expect(response.body).not_to include("1,234.56")
    end

    it "shows an in-scope payroll viewer the current salary only, never the history" do
      sign_in branch_manager_of(branch_a, :view_employees, :view_payroll)
      get admin_user_path(emp_a)

      expect(response.body).to include("4,321.98")
      expect(response.body).not_to include("1,234.56")
    end

    it "shows the employee their own current salary only on their own page" do
      manager = branch_manager_of(branch_a, :view_employees, :view_payroll)
      salary_history_for(manager)
      sign_in manager
      get admin_user_path(manager)

      expect(response.body).to include("4,321.98")
      expect(response.body).not_to include("1,234.56")
    end
  end

  describe "changing salary profiles" do
    let(:salary_admin) do
      branch_manager_of(branch_a, :view_employees, :view_payroll, :manage_salary_profiles)
    end
    let(:new_profile_params) do
      { salary_profile: { salary_type: "monthly", base_amount: "9000", effective_from: Date.current.iso8601 } }
    end

    before { salary_history_for(salary_admin) }

    it "refuses creating one's own salary profile (admin)" do
      sign_in salary_admin

      expect { post admin_user_salary_profiles_path(salary_admin), params: new_profile_params }
        .not_to change(SalaryProfile, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses creating one's own salary profile (API)" do
      sign_in salary_admin

      expect { post "/api/v1/users/#{salary_admin.id}/salary_profiles", params: new_profile_params, as: :json }
        .not_to change(SalaryProfile, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "refuses changing one's own salary profile (admin)" do
      own_current = salary_admin.salary_profiles.find_by(active: true)
      sign_in salary_admin

      patch admin_user_salary_profile_path(salary_admin, own_current), params: { salary_profile: { base_amount: "9999" } }
      expect(response).to have_http_status(:not_found)
      expect(own_current.reload.base_amount).to eq(4321.98)
    end

    it "refuses changing one's own salary profile (API)" do
      own_current = salary_admin.salary_profiles.find_by(active: true)
      sign_in salary_admin

      patch "/api/v1/users/#{salary_admin.id}/salary_profiles/#{own_current.id}",
            params: { salary_profile: { base_amount: "9999" } }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(own_current.reload.base_amount).to eq(4321.98)
    end

    it "still allows managing an in-scope employee's salary (admin and API)" do
      sign_in salary_admin

      expect { post admin_user_salary_profiles_path(emp_a), params: new_profile_params }
        .to change { emp_a.salary_profiles.count }.by(1)
      expect(response).to redirect_to(admin_user_path(emp_a))

      post "/api/v1/users/#{emp_a.id}/salary_profiles",
           params: { salary_profile: { salary_type: "monthly", base_amount: "9100",
                                       effective_from: (Date.current + 1).iso8601 } }, as: :json
      expect(response).to have_http_status(:created)
    end

    it "refuses managing an employee outside the manage_salary_profiles scope" do
      sign_in salary_admin

      expect { post admin_user_salary_profiles_path(emp_b), params: new_profile_params }
        .not_to change(SalaryProfile, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "salary view audit" do
    it "records a self view with its source, without amounts" do
      sign_in emp_a
      expect { api_index(emp_a) }.to change(salary_views, :count).by(1)

      log = salary_views.last
      expect(log).to have_attributes(actor_id: emp_a.id, auditable: emp_a, business_id: business.id)
      expect(log.metadata).to eq("source" => "api_salary_profiles", "self_view" => true,
                                 "salary_profile_ids" => [ a_profiles[:current].id ])
      expect(log.changes_json).to eq({})
      expect(log.to_json).not_to include("4321.98")
    end

    it "records an authorized view of another employee on the employee page, the API and the edit page" do
      manager = branch_manager_of(branch_a, :view_employees, :view_payroll, :manage_salary_profiles)
      sign_in manager

      expect { get admin_user_path(emp_a) }.to change(salary_views, :count).by(1)
      expect(salary_views.last.metadata).to include("source" => "admin_employee_page", "self_view" => false)

      expect { api_show(emp_a, a_profiles[:current]) }.to change(salary_views, :count).by(1)
      expect(salary_views.last.metadata["source"]).to eq("api_salary_profile")

      expect { get edit_admin_user_salary_profile_path(emp_a, a_profiles[:current]) }.to change(salary_views, :count).by(1)
      expect(salary_views.last.metadata["source"]).to eq("admin_salary_profile_edit")
    end

    it "records nothing when no salary was shown" do
      sign_in role_user(:view_employees, scopes: { "view_employees" => "business" })

      expect { get admin_user_path(emp_a) }.not_to change(salary_views, :count)
      expect { api_index(emp_a) }.not_to change(salary_views, :count)
      expect { api_show(emp_a, a_profiles[:current]) }.not_to change(salary_views, :count)
    end
  end

  describe "the owner's own salary profile (no owner exception)" do
    let(:new_profile_params) do
      { salary_profile: { salary_type: "monthly", base_amount: "9000", effective_from: Date.current.iso8601 } }
    end
    let!(:own) { salary_history_for(owner) }

    before { sign_in owner }

    it "refuses creating it (admin)" do
      expect { post admin_user_salary_profiles_path(owner), params: new_profile_params }
        .not_to change(SalaryProfile, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses opening the new / edit forms (admin)" do
      get new_admin_user_salary_profile_path(owner)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses changing it (admin)" do
      patch admin_user_salary_profile_path(owner, own[:current]), params: { salary_profile: { base_amount: "9999" } }
      expect(response).to have_http_status(:not_found)
      expect(own[:current].reload.base_amount).to eq(4321.98)
    end

    it "refuses creating it (API)" do
      expect { post "/api/v1/users/#{owner.id}/salary_profiles", params: new_profile_params, as: :json }
        .not_to change(SalaryProfile, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "refuses changing it (API)" do
      patch "/api/v1/users/#{owner.id}/salary_profiles/#{own[:current].id}",
            params: { salary_profile: { base_amount: "9999" } }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(own[:current].reload.base_amount).to eq(4321.98)
    end

    it "still lets the owner see their own current salary" do
      api_index(owner)
      expect(returned_ids).to eq([ own[:current].id ])
    end

    it "still lets the owner manage another employee's salary" do
      expect { post admin_user_salary_profiles_path(emp_a), params: new_profile_params }
        .to change { emp_a.salary_profiles.count }.by(1)

      current = emp_a.salary_profiles.find_by(active: true)
      patch "/api/v1/users/#{emp_a.id}/salary_profiles/#{current.id}",
            params: { salary_profile: { base_amount: "9500" } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(current.reload.base_amount).to eq(9500)
    end
  end

  describe "a business-wide salary administrator's own profile" do
    let(:admin) do
      role_user(:view_employees, :view_payroll, :manage_salary_profiles,
                scopes: { "view_employees" => "business", "view_payroll" => "business",
                          "manage_salary_profiles" => "business" })
    end
    let!(:own) { salary_history_for(admin) }

    before { sign_in admin }

    it "cannot be created by them through admin" do
      expect { post admin_user_salary_profiles_path(admin), params: { salary_profile: { base_amount: "1" } } }
        .not_to change(SalaryProfile, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "cannot be created or changed by them through the API" do
      expect { post "/api/v1/users/#{admin.id}/salary_profiles", params: { salary_profile: { base_amount: "1" } }, as: :json }
        .not_to change(SalaryProfile, :count)
      expect(response).to have_http_status(:forbidden)

      patch "/api/v1/users/#{admin.id}/salary_profiles/#{own[:current].id}",
            params: { salary_profile: { base_amount: "1" } }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(own[:current].reload.base_amount).to eq(4321.98)
    end
  end

  describe "salary administration responses" do
    let(:salary_admin) { branch_manager_of(branch_a, :view_employees, :view_payroll, :manage_salary_profiles) }

    before { sign_in salary_admin }

    it "API create returns only the new profile, no history, and records no salary view" do
      expect do
        post "/api/v1/users/#{emp_a.id}/salary_profiles",
             params: { salary_profile: { salary_type: "monthly", base_amount: "7654.32",
                                         effective_from: Date.current.iso8601 } }, as: :json
      end.not_to change(salary_views, :count)

      expect(response).to have_http_status(:created)
      expect(api_data["base_amount"].to_d).to eq(BigDecimal("7654.32"))
      expect(response.body).not_to include("1234.56", "4321.98")
      expect(emp_a.salary_profiles.count).to eq(3) # history kept
    end

    it "API update of the current profile returns it and records a salary view, without amounts" do
      expect do
        patch "/api/v1/users/#{emp_a.id}/salary_profiles/#{a_profiles[:current].id}",
              params: { salary_profile: { base_amount: "4400" } }, as: :json
      end.to change(salary_views, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("1234.56")
      log = salary_views.last
      expect(log.metadata).to eq("source" => "api_salary_profile_update", "self_view" => false,
                                 "salary_profile_ids" => [ a_profiles[:current].id ])
      expect(log.to_json).not_to include("4400.0") # decimal: ids may contain the bare digits
    end

    it "refuses updating a historical profile without disclosing it (admin and API)" do
      expect do
        patch "/api/v1/users/#{emp_a.id}/salary_profiles/#{a_profiles[:historical].id}",
              params: { salary_profile: { base_amount: "1" } }, as: :json
      end.not_to change(salary_views, :count)
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include("1234.56")

      get edit_admin_user_salary_profile_path(emp_a, a_profiles[:historical])
      expect(response).to redirect_to(root_path)
      expect(a_profiles[:historical].reload.base_amount).to eq(1234.56)
    end

    it "records no salary view for a refused update" do
      other_admin = role_user(:view_employees, :manage_salary_profiles, scopes: { "view_employees" => "business" })
      branch_a.update_column(:branch_manager_id, other_admin.id)
      sign_in other_admin

      expect do
        patch "/api/v1/users/#{emp_a.id}/salary_profiles/#{a_profiles[:current].id}",
              params: { salary_profile: { base_amount: "1" } }, as: :json
      end.not_to change(salary_views, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end

  # manage_salary_profiles does not grant reading salary amounts.
  describe "manage-only, view-only and combined salary permissions" do
    let(:new_profile_params) do
      { salary_profile: { salary_type: "monthly", base_amount: "5555", effective_from: Date.current.iso8601 } }
    end
    let(:manage_only) { branch_manager_of(branch_a, :view_employees, :manage_salary_profiles) }
    let(:view_only)   { branch_manager_of(branch_a, :view_employees, :view_payroll) }
    let(:combined)    { branch_manager_of(branch_a, :view_employees, :view_payroll, :manage_salary_profiles) }

    def expect_no_amounts
      expect(response.body).not_to include("4321.98", "4,321.98", "1234.56", "1,234.56")
    end

    context "manage-only (manage_salary_profiles without view_payroll)" do
      before { sign_in manage_only }

      it "sees the salary card's create action on the employee page, but no amounts" do
        expect { get admin_user_path(emp_a) }.not_to change(salary_views, :count)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(new_admin_user_salary_profile_path(emp_a))
        expect_no_amounts
      end

      it "can create a new profile for an in-scope employee (admin and API), seeing nothing existing" do
        get new_admin_user_salary_profile_path(emp_a)
        expect(response).to have_http_status(:ok)
        expect_no_amounts

        expect { post admin_user_salary_profiles_path(emp_a), params: new_profile_params }
          .to change { emp_a.salary_profiles.count }.by(1)

        post "/api/v1/users/#{emp_a.id}/salary_profiles",
             params: { salary_profile: { salary_type: "monthly", base_amount: "5600",
                                         effective_from: (Date.current + 1).iso8601 } }, as: :json
        expect(response).to have_http_status(:created)
        expect_no_amounts
      end

      it "cannot open the edit form or change the current profile in place (admin)" do
        get edit_admin_user_salary_profile_path(emp_a, a_profiles[:current])
        expect(response).to redirect_to(root_path)
        follow_redirect!
        expect_no_amounts

        patch admin_user_salary_profile_path(emp_a, a_profiles[:current]), params: { salary_profile: { base_amount: "1" } }
        expect(response).to redirect_to(root_path)
        expect(a_profiles[:current].reload.base_amount).to eq(4321.98)
      end

      it "cannot read or change it through the API" do
        api_index(emp_a)
        expect(api_data).to eq([])

        api_show(emp_a, a_profiles[:current])
        expect(response).to have_http_status(:not_found)

        patch "/api/v1/users/#{emp_a.id}/salary_profiles/#{a_profiles[:current].id}",
              params: { salary_profile: { currency: "USD" } }, as: :json
        expect(response).to have_http_status(:forbidden)
        expect_no_amounts
        expect(a_profiles[:current].reload.currency).not_to eq("USD")
      end

      it "cannot manage an employee outside the scope" do
        expect { post admin_user_salary_profiles_path(emp_b), params: new_profile_params }.not_to change(SalaryProfile, :count)
        expect(response).to have_http_status(:not_found)
      end

      it "cannot manage their own salary" do
        expect { post admin_user_salary_profiles_path(manage_only), params: new_profile_params }.not_to change(SalaryProfile, :count)
        expect(response).to have_http_status(:not_found)
      end
    end

    context "view-only (view_payroll without manage_salary_profiles)" do
      before { sign_in view_only }

      it "sees the current amount on the employee page, without the create action" do
        get admin_user_path(emp_a)
        expect(response.body).to include("4,321.98")
        expect(response.body).not_to include(new_admin_user_salary_profile_path(emp_a))
      end

      it "cannot open the new form (admin)" do
        get new_admin_user_salary_profile_path(emp_a)
        expect(response).to redirect_to(root_path) # Admin::SalaryProfilesController#require_admin_access!
        expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      end

      it "cannot open the edit form (admin)" do
        get edit_admin_user_salary_profile_path(emp_a, a_profiles[:current])
        expect(response).to redirect_to(root_path) # Admin::SalaryProfilesController#require_admin_access!
        expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      end

      it "cannot create or change through the API" do
        expect { post "/api/v1/users/#{emp_a.id}/salary_profiles", params: new_profile_params, as: :json }
          .not_to change(SalaryProfile, :count)
        expect(response).to have_http_status(:forbidden)

        patch "/api/v1/users/#{emp_a.id}/salary_profiles/#{a_profiles[:current].id}",
              params: { salary_profile: { base_amount: "1" } }, as: :json
        expect(response).to have_http_status(:forbidden)
        expect(a_profiles[:current].reload.base_amount).to eq(4321.98)
      end
    end

    context "combined (view_payroll and manage_salary_profiles)" do
      before { sign_in combined }

      it "edits an in-scope employee's current profile, never the history" do
        get edit_admin_user_salary_profile_path(emp_a, a_profiles[:current])
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("1234.56")

        patch admin_user_salary_profile_path(emp_a, a_profiles[:current]), params: { salary_profile: { base_amount: "4500" } }
        expect(response).to redirect_to(admin_user_path(emp_a))
        expect(a_profiles[:current].reload.base_amount).to eq(4500)
      end

      it "cannot edit an employee outside the scope" do
        get edit_admin_user_salary_profile_path(emp_b, b_profiles[:current])
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # Salary-profile changes go through Salary::ProfileUpdater (create) and
  # Salary::ProfileCorrector (update) and are audited there — once, after
  # success, naming fields and dates but never amounts.
  describe "salary profile change audit" do
    let(:salary_admin) { branch_manager_of(branch_a, :view_employees, :view_payroll, :manage_salary_profiles) }
    let(:changes) { AuditLog.where(auditable_type: "SalaryProfile") }

    before { sign_in salary_admin }

    def expect_no_amounts_in(log)
      expect(log.to_json).not_to include("7777.0", "8888.0", "4321.98", "1234.56") # decimals: ids may contain the bare digits
    end

    it "admin create: one 'create' event with the source, the superseded profile and no amounts" do
      expect do
        post admin_user_salary_profiles_path(emp_a),
             params: { salary_profile: { salary_type: "monthly", base_amount: "7777", effective_from: "2026-11-01" } }
      end.to change(changes, :count).by(1)

      created = emp_a.salary_profiles.order(:id).last
      log = changes.last
      expect(log).to have_attributes(action: "create", auditable: created, actor_id: salary_admin.id, business_id: business.id)
      expect(log.metadata).to eq("source" => "admin", "user_id" => emp_a.id, "salary_type" => "monthly",
                                 "effective_from" => "2026-11-01",
                                 "superseded_profile_ids" => [ a_profiles[:current].id ])
      expect_no_amounts_in(log)
    end

    it "API create: one 'create' event with source api" do
      expect do
        post "/api/v1/users/#{emp_a.id}/salary_profiles",
             params: { salary_profile: { salary_type: "monthly", base_amount: "7777", effective_from: "2026-11-01" } }, as: :json
      end.to change(changes, :count).by(1)

      expect(changes.last.metadata).to include("source" => "api", "user_id" => emp_a.id)
      expect_no_amounts_in(changes.last)
    end

    it "admin update: one 'update' event naming the corrected fields only" do
      expect do
        patch admin_user_salary_profile_path(emp_a, a_profiles[:current]),
              params: { salary_profile: { base_amount: "8888", overtime_multiplier: "1.75" } }
      end.to change(changes, :count).by(1)

      log = changes.last
      expect(log).to have_attributes(action: "update", auditable: a_profiles[:current], actor_id: salary_admin.id)
      expect(log.metadata).to eq("source" => "admin", "user_id" => emp_a.id,
                                 "changed_fields" => %w[base_amount overtime_multiplier])
      expect(log.changes_json).to eq({})
      expect_no_amounts_in(log)
    end

    it "API update: one 'update' event, plus the response's salary view" do
      expect do
        patch "/api/v1/users/#{emp_a.id}/salary_profiles/#{a_profiles[:current].id}",
              params: { salary_profile: { base_amount: "8888" } }, as: :json
      end.to change(changes, :count).by(1).and change(salary_views, :count).by(1)

      expect(changes.last.metadata).to eq("source" => "api", "user_id" => emp_a.id, "changed_fields" => [ "base_amount" ])
    end

    it "writes nothing for a submission that changes nothing" do
      expect do
        patch admin_user_salary_profile_path(emp_a, a_profiles[:current]), params: { salary_profile: { base_amount: "4321.98" } }
      end.not_to change(changes, :count)
    end

    it "writes nothing for an invalid change (admin re-renders the form with the errors)" do
      expect do
        post admin_user_salary_profiles_path(emp_a),
             params: { salary_profile: { salary_type: "monthly", base_amount: "-5", effective_from: "2026-11-01" } }
      end.not_to change(changes, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(emp_a.salary_profiles.find_by(active: true)).to eq(a_profiles[:current])

      expect do
        patch "/api/v1/users/#{emp_a.id}/salary_profiles/#{a_profiles[:current].id}",
              params: { salary_profile: { base_amount: "-5" } }, as: :json
      end.not_to change(changes, :count)
      expect(a_profiles[:current].reload.base_amount).to eq(4321.98)
    end

    it "writes nothing for a refused change" do
      expect do
        patch admin_user_salary_profile_path(emp_b, b_profiles[:current]), params: { salary_profile: { base_amount: "8888" } }
      end.not_to change(changes, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "a manage-only actor's create is audited, and the audit shows them no amounts" do
      manage_only = branch_manager_of(branch_a, :view_employees, :manage_salary_profiles)
      sign_in manage_only

      expect do
        post admin_user_salary_profiles_path(emp_a),
             params: { salary_profile: { salary_type: "monthly", base_amount: "7777", effective_from: "2026-11-01" } }
      end.to change(changes, :count).by(1)
      expect(changes.last.actor_id).to eq(manage_only.id)
      expect_no_amounts_in(changes.last)
    end
  end
end
