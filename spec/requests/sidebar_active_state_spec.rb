require "rails_helper"

RSpec.describe "Sidebar collapsible groups", type: :request do
  let(:business)    { create(:business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  before { sign_in super_admin }

  it "department field on user form is a select (no free text)" do
    get new_admin_user_path
    expect(response.body).to include('name="user[department_id]"')
    expect(response.body).not_to include('id="department-suggestions"')
    expect(response.body).not_to include('name="user[department]"')
  end

  # One <details class="sidebar__group"> per collapsible section, each with a
  # stable data-sidebar-group-key-value used both for the sessionStorage key
  # and to derive the unique aria-controls/content id — see
  # _sidebar_group.html.erb.
  GROUPS = {
    "performance"    => { path: :performance_root_path, label_key: "nav.section_performance" },
    "administration" => { path: :admin_settings_path,   label_key: "nav.section_administration" }
  }.freeze
  # Finance, Inventory and Laundry are no longer collapsible groups: each is a
  # single entry point into a workspace whose sections live in the workspace's
  # own nav (see spec/requests/inventory/workspace_navigation_spec.rb and
  # spec/requests/finance_laundry_workspace_navigation_spec.rb).

  def group_details_regex(key, open:)
    open_attr = open ? "\\s+open" : ""
    /<details class="sidebar__group"#{open_attr}[^>]*data-sidebar-group-key-value="#{key}"[^>]*>/m
  end

  GROUPS.each do |key, cfg|
    describe "#{key} group" do
      it "renders the collapsible header with the translated label, correct aria attributes, and a unique content id" do
        get send(cfg[:path])
        body = response.body

        expect(body).to match(group_details_regex(key, open: true))
        expect(body).to include(%(aria-controls="sidebar-group-#{key}"))
        expect(body).to include(%(aria-expanded="true"))
        expect(body).to include(%(id="sidebar-group-#{key}"))
        expect(body).to include(I18n.t(cfg[:label_key]))
      end

      it "expands (open + aria-expanded=true) when the active page belongs to this group" do
        get send(cfg[:path])
        expect(response.body).to match(group_details_regex(key, open: true))
        active_in_group = Nokogiri::HTML(response.body)
          .css(%(details[data-sidebar-group-key-value="#{key}"] a.sidebar__nav-item.is-active))
        expect(active_in_group.size).to eq(1)
      end

      it "renders collapsed by default when the current page is unrelated to this group" do
        get root_path
        body = response.body
        expect(body).to match(group_details_regex(key, open: false))
        expect(body).not_to match(group_details_regex(key, open: true))
      end
    end
  end

  it "gives every group a unique content id and aria-controls pair — no duplicate HTML ids" do
    get root_path
    ids = response.body.scan(/id="(sidebar-group-[a-z]+)"/).flatten
    expect(ids).not_to be_empty
    expect(ids.uniq.length).to eq(ids.length)
  end

  it "expands multiple groups independently without collapsing others (not an accordion)" do
    get performance_root_path
    body = response.body
    expect(body).to match(group_details_regex("performance", open: true))
    # Administration's <details> (closed) is still present in the same
    # document — independent groups, not an accordion.
    expect(body).to match(group_details_regex("administration", open: false))
  end

  it "keeps all previously existing navigation links present under their groups" do
    get root_path
    body = response.body

    # Performance
    expect(body).to include(performance_root_path, performance_observations_path,
                            performance_reviews_path, performance_reports_path)
    # Finance, Inventory, Laundry — one entry each in the main sidebar; every
    # former link is still one click away in the workspace navigation.
    expect(body).to include(finance_root_path, inventory_root_path, laundry_root_path)

    get laundry_root_path
    expect(response.body).to include(laundry_towel_balances_path, laundry_towel_transfers_path,
                                     laundry_towel_adjustments_path, laundry_towel_types_path,
                                     laundry_reports_branch_consumption_path, laundry_reports_cost_summary_path)
    get finance_root_path
    expect(response.body).to include(finance_expenses_path, finance_custody_accounts_path,
                                     finance_reports_path, finance_daily_reconciliations_path)
    get inventory_root_path
    expect(response.body).to include(inventory_products_path, inventory_warehouses_path,
                                     inventory_suppliers_path, inventory_goods_receipts_path, inventory_stock_issues_path,
                                     inventory_stock_transfers_path, inventory_stock_adjustments_path,
                                     inventory_stock_counts_path, inventory_reports_path)
  end

  it "hides a module entirely when the user has no access to it" do
    role = business.permission_roles.create!(name: "Zero Perms", permissions: [])
    no_access = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    sign_in no_access

    get root_path
    body = response.body

    expect(body).not_to include(%(href="#{laundry_root_path}"))
    expect(body).not_to include(I18n.t("nav.section_laundry"))
    expect(body).not_to include(laundry_towel_transfers_path)
  end

  it "shows only the authorized links in a visible module's workspace (no unauthorized links leak into the HTML)" do
    role = business.permission_roles.create!(name: "Laundry Viewer Only", permissions: %w[view_towel_balances])
    viewer = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    sign_in viewer

    get root_path
    expect(response.body).to include(%(href="#{laundry_root_path}"))

    get laundry_root_path
    body = response.body
    expect(body).to include(laundry_towel_balances_path)
    expect(body).not_to include(laundry_towel_types_path) # requires configure_towel_usage_expectations
  end

  it "shows Inventory as a single highlighted entry (not a group) on an inventory page" do
    get inventory_stock_issues_path
    html = Nokogiri::HTML(response.body)
    expect(response.body).not_to include(%(data-sidebar-group-key-value="inventory"))
    active = html.css(".sidebar a.sidebar__nav-item.is-active")
    expect(active.map { |a| a["href"] }).to eq([ inventory_root_path ])
    expect(active.text).to include(I18n.t("nav.inventory_workspace"))
  end

  it "expands the Performance group on a performance page" do
    get performance_root_path
    html = response.body
    expect(html).to match(group_details_regex("performance", open: true))
    expect(html).to include("is-active")
  end

  it "works the same under the Arabic locale (RTL)" do
    super_admin.update!(preferred_locale: "ar")
    get performance_root_path(locale: :ar)
    body = response.body

    expect(body).to include('dir="rtl"')
    expect(body).to match(group_details_regex("performance", open: true))
    expect(Nokogiri::HTML(body).css(%(details[data-sidebar-group-key-value="performance"] a.sidebar__nav-item.is-active)).size).to eq(1)
    expect(body).to include(I18n.t("nav.section_performance", locale: :ar))
  end

  it "renders correctly under English (LTR) with the same component, no duplicated markup" do
    super_admin.update!(preferred_locale: "en")
    get performance_root_path
    body = response.body

    expect(body).to include('dir="ltr"')
    expect(body).to match(group_details_regex("performance", open: true))
    # The group markup for a given key appears exactly once per render.
    expect(body.scan(%(data-sidebar-group-key-value="performance")).length).to eq(1)
  end

  describe "main sidebar structure" do
    def html = Nokogiri::HTML(response.body)
    # Every section in order: collapsible groups (<details>) and plain single-item sections (<div>).
    def section_keys = html.css(".sidebar [data-sidebar-group-key-value], .sidebar [data-sidebar-section-key]")
                           .map { |n| n["data-sidebar-group-key-value"] || n["data-sidebar-section-key"] }
    def collapsible_keys = html.css(".sidebar details.sidebar__group").map { |d| d["data-sidebar-group-key-value"] }
    def plain_keys = html.css(".sidebar div.sidebar__section").map { |d| d["data-sidebar-section-key"] }
    def section_hrefs(key) = html.css(%(.sidebar [data-sidebar-group-key-value="#{key}"] a.sidebar__nav-item,
                                        .sidebar [data-sidebar-section-key="#{key}"] a.sidebar__nav-item)).map { |a| a["href"] }
    def open_keys = html.css(".sidebar details.sidebar__group[open]").map { |d| d["data-sidebar-group-key-value"] }

    def user_with(*perms)
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms.map(&:to_s))
      create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    end

    it "orders the sections by workflow with the expected headings" do
      get root_path
      expect(section_keys).to eq(%w[home employees attendance payroll requests workspaces performance administration])
      expect(html.css(".sidebar .sidebar__group-label").map(&:text))
        .to eq(%w[nav.home nav.section_employees nav.section_attendance_shifts nav.section_payroll nav.section_requests
                  nav.section_workspaces nav.section_performance nav.section_administration].map { |k| I18n.t(k) })
    end

    it "makes only multi-item sections collapsible; Requests is a plain heading + link with no chevron" do
      get root_path
      expect(collapsible_keys).to eq(%w[home employees attendance payroll workspaces performance administration])
      expect(plain_keys).to eq(%w[requests])
      requests = html.at_css('.sidebar [data-sidebar-section-key="requests"]')
      expect(requests.css(".sidebar__group-chevron, summary")).to be_empty
      expect(requests["data-controller"]).to be_nil # no remembered expand/collapse state
    end

    it "puts each page in its section, in order, with workspaces as single entries" do
      get root_path
      expect(section_hrefs("home")).to eq([ root_path, operations_dashboard_path ])
      expect(section_hrefs("employees")).to eq([ admin_users_path, admin_branches_path, admin_employee_obligations_path ])
      expect(section_hrefs("attendance")).to eq([ admin_shifts_path, shift_assignments_path, admin_shift_rule_profiles_path,
                                                  attendance_records_path, admin_biometric_punch_logs_path ])
      expect(section_hrefs("payroll")).to eq([ payroll_periods_path, adjustments_path ])
      expect(section_hrefs("requests")).to eq([ employee_requests_path ])
      expect(section_hrefs("workspaces")).to eq([ finance_root_path, inventory_root_path, laundry_root_path ])
      expect(section_hrefs("performance")).to eq([ performance_root_path, performance_observations_path,
                                                   performance_reviews_path, performance_reports_path ])
      # Administration holds system configuration only — no employee obligations.
      expect(section_hrefs("administration")).to eq([ admin_biometric_devices_path, admin_permission_roles_path,
                                                      admin_settings_path, admin_departments_path,
                                                      admin_evaluation_templates_path ])
    end

    it "starts the everyday groups open and Performance / Administration closed" do
      get root_path
      expect(open_keys).to eq(%w[home employees attendance payroll workspaces])
    end

    {
      inventory_purchase_requests_path: :inventory_root_path,
      finance_expenses_path:            :finance_root_path,
      laundry_towel_transfers_path:     :laundry_root_path
    }.each do |page, entry|
      it "on #{page} highlights only the workspace entry (level 1), never a child page" do
        get send(page)
        active = html.css(".sidebar a.sidebar__nav-item.is-active").map { |a| a["href"] }
        expect(active).to eq([ send(entry) ])
        expect(open_keys).to include("workspaces")
      end
    end

    it "opens the Employees group on the employee obligations page" do
      get admin_employee_obligations_path
      expect(open_keys).to include("employees")
      expect(html.css(".sidebar a.sidebar__nav-item.is-active").map { |a| a["href"] }).to eq([ admin_employee_obligations_path ])
    end

    it "opens a normally-closed group when it holds the active page" do
      get admin_settings_path
      expect(open_keys).to include("administration")
      expect(html.css(".sidebar a.sidebar__nav-item.is-active").map { |a| a["href"] }).to eq([ admin_settings_path ])
    end

    it "after permission filtering: hides empty sections and renders one-item sections without a collapse control" do
      sign_in user_with(:view_shifts, :assign_shifts, :view_payroll)
      get root_path
      expect(section_keys).to eq(%w[home attendance payroll])
      expect(collapsible_keys).to be_empty
      expect(html.css(".sidebar .sidebar__group-chevron")).to be_empty
      expect(section_hrefs("attendance")).to eq([ shift_assignments_path ])
      expect(section_hrefs("payroll")).to eq([ payroll_periods_path ])
      expect(section_hrefs("home")).to eq([ root_path ])
    end

    it "keeps a filtered group collapsible while two or more of its pages remain" do
      sign_in user_with(:view_employees, :view_payroll, :manage_obligations)
      get root_path
      expect(collapsible_keys).to include("employees")
      expect(section_hrefs("employees")).to eq([ admin_users_path, admin_employee_obligations_path ])
      # …while Payroll, down to one visible page for this user, renders plain.
      expect(plain_keys).to include("payroll")
      expect(section_hrefs("payroll")).to eq([ payroll_periods_path ])
    end
  end

  it "Super Admin continues to see every collapsible group and every link inside them" do
    get root_path
    body = response.body

    GROUPS.each_key { |key| expect(body).to match(group_details_regex(key, open: false)) }
    expect(body).to include(I18n.t("nav.section_administration"))
  end
end
