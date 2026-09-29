require "rails_helper"

# Two separate workflows, two separate permission sets:
#   A) direct employee creation ("إضافة موظف")   — manage_employees (UserPolicy#create?)
#   B) Employee Add Requests (طلبات إضافة الموظفين) — the employee_onboarding group
# Neither grants the other; the sidebar nests B under "Employees".
RSpec.describe "Employees sidebar and direct employee creation", type: :request do
  let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
  let(:onboarding_permissions) { PermissionRole::PERMISSION_GROUPS[:employee_onboarding] }

  # A permission plus everything it depends on (roles must satisfy dependencies).
  def with_dependencies(*perms)
    perms.map(&:to_s).flat_map { |p| [ p, *with_dependencies(*PermissionRole::PERMISSION_DEPENDENCIES.fetch(p, [])) ] }.uniq
  end

  def user_with(*perms, **attrs)
    edr_user_with(*with_dependencies(*perms), business: business, preferred_locale: "ar", **attrs)
  end

  def html_of(path)
    get path
    Nokogiri::HTML(response.body)
  end

  def add_employee_button(html) = html.at_css("[data-testid='add-employee']")
  def sidebar_link(html)        = html.css(".sidebar [data-testid='nav-employee-data-requests']")

  # The sidebar group (collapsible <details> or plain section) containing `node`.
  def sidebar_group_key(node)
    node.ancestors.find { |a| a["data-sidebar-group-key-value"] || a["data-sidebar-section-key"] }
        &.then { |g| g["data-sidebar-group-key-value"] || g["data-sidebar-section-key"] }
  end

  let(:new_employee_params) do
    { user: { first_name: "سارة", last_name: "علي", phone_number: "01055555555" } }
  end

  describe "direct employee creation (إضافة موظف)" do
    it "hides the button from a user who can view but not manage employees" do # 1
      sign_in user_with(:view_employees)
      expect(add_employee_button(html_of(admin_users_path))).to be_nil
    end

    it "blocks the creation page and endpoint without manage_employees, even by direct URL" do # 2, 3
      sign_in user_with(:view_employees)
      get new_admin_user_path
      expect(response).to redirect_to(root_path)
      expect { post admin_users_path, params: new_employee_params }.not_to change(User, :count)
      expect(response).to redirect_to(root_path)
    end

    it "is not granted by any Employee Add Request permission" do # 4, 5
      requester = user_with(:create_employee_requests, :view_employees)
      sign_in requester
      expect(add_employee_button(html_of(admin_users_path))).to be_nil
      get new_admin_user_path
      expect(response).to redirect_to(root_path)
      expect { post admin_users_path, params: new_employee_params }.not_to change(User, :count)

      # …while the same user can submit an Employee Add Request.
      expect { post employee_data_requests_path, params: { employee_data_request: edr_params } }
        .to change(EmployeeDataRequest, :count).by(1)
    end

    it "is not granted by reviewer/approver request permissions either" do
      reviewer = user_with(*onboarding_permissions, scopes: { view_all_employee_requests: "business" })
      sign_in reviewer
      get new_admin_user_path
      expect(response).to redirect_to(root_path)
      expect { post admin_users_path, params: new_employee_params }.not_to change(User, :count)
    end

    it "works exactly as before with manage_employees" do # 10
      sign_in user_with(:manage_employees)
      expect(add_employee_button(html_of(admin_users_path))).to be_present
      get new_admin_user_path
      expect(response).to have_http_status(:ok)
      expect { post admin_users_path, params: new_employee_params }.to change(User, :count).by(1)
      expect(response).to redirect_to(admin_users_path)
    end

    it "shows the button to the super admin (owner)" do
      owner = create(:user, business: business).tap { |u| business.update!(owner: u) }
      sign_in owner
      expect(add_employee_button(html_of(admin_users_path))).to be_present
    end
  end

  describe "sidebar" do
    it "nests Employee Add Requests under Employees, never as a top-level item" do # 6, 7
      sign_in user_with(:create_employee_requests, :view_employees)
      links = sidebar_link(html_of(root_path))
      expect(links.size).to eq(1)
      expect(sidebar_group_key(links.first)).to eq("employees")
      expect(links.first.text.strip).to eq("طلبات إضافة الموظفين")
      # Plain employees link sits in the same group.
      employees_link = html_of(root_path).at_css(".sidebar a[href='#{admin_users_path}']")
      expect(sidebar_group_key(employees_link)).to eq("employees")
    end

    it "still nests it under Employees for a requester who can't view employees" do # 4
      sign_in user_with(:create_employee_requests)
      html = html_of(root_path)
      expect(sidebar_group_key(sidebar_link(html).first)).to eq("employees")
      expect(html.at_css(".sidebar a[href='#{admin_users_path}']")).to be_nil
    end

    it "hides the entry from users with no Employee Add Request permission" do # 8
      sign_in user_with(:view_employees, :manage_employees)
      expect(sidebar_link(html_of(root_path))).to be_empty
      get employee_data_requests_path
      expect(response).to redirect_to(root_path)
    end

    it "shows the entry for each Employee Add Request permission" do # 9
      onboarding_permissions.each do |perm|
        sign_in user_with(perm)
        expect(sidebar_link(html_of(root_path)).size).to eq(1), "#{perm} did not show the entry"
        get employee_data_requests_path
        expect(response).to have_http_status(:ok), "#{perm} could not open the list"
      end
    end

    it "shows everything to the super admin" do
      owner = create(:user, business: business).tap { |u| business.update!(owner: u) }
      sign_in owner
      html = html_of(root_path)
      expect(sidebar_group_key(sidebar_link(html).first)).to eq("employees")
      expect(html.at_css(".sidebar a[href='#{admin_users_path}']")).to be_present
    end
  end
end
