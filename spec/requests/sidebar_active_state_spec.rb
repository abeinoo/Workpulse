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
    "performance" => { path: :performance_root_path, label_key: "nav.section_performance" },
    "laundry"     => { path: :laundry_root_path,     label_key: "nav.section_laundry" },
    "finance"     => { path: :finance_root_path,     label_key: "nav.section_finance" },
    "inventory"   => { path: :inventory_root_path,   label_key: "nav.section_inventory" }
  }.freeze

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
        expect(response.body).to include("sidebar__nav-item--sub is-active")
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
    get inventory_root_path
    body = response.body
    expect(body).to match(group_details_regex("inventory", open: true))
    # Laundry's <details> (closed) is still present in the same document —
    # independent groups, not an accordion.
    expect(body).to match(group_details_regex("laundry", open: false))
  end

  it "keeps all previously existing navigation links present under their groups" do
    get root_path
    body = response.body

    # Performance
    expect(body).to include(performance_root_path, performance_observations_path,
                            performance_reviews_path, performance_reports_path)
    # Laundry
    expect(body).to include(laundry_root_path, laundry_towel_balances_path, laundry_towel_transfers_path,
                            laundry_towel_adjustments_path, laundry_towel_types_path,
                            laundry_reports_branch_consumption_path, laundry_reports_cost_summary_path)
    # Finance
    expect(body).to include(finance_root_path, finance_expenses_path, finance_custody_accounts_path,
                            finance_reports_path, finance_daily_reconciliations_path)
    # Inventory
    expect(body).to include(inventory_root_path, inventory_products_path, inventory_warehouses_path,
                            inventory_suppliers_path, inventory_goods_receipts_path, inventory_stock_issues_path,
                            inventory_stock_transfers_path, inventory_stock_adjustments_path,
                            inventory_stock_counts_path, inventory_reports_path)
  end

  it "hides a group entirely when the user has no accessible children, and never renders it empty" do
    role = business.permission_roles.create!(name: "Zero Perms", permissions: [])
    no_access = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    sign_in no_access

    get root_path
    body = response.body

    expect(body).not_to match(group_details_regex("laundry", open: false))
    expect(body).not_to match(group_details_regex("laundry", open: true))
    expect(body).not_to include(I18n.t("nav.section_laundry"))
    expect(body).not_to include(laundry_towel_transfers_path)
  end

  it "shows only the authorized child links inside an otherwise-visible group (no unauthorized links leak into the HTML)" do
    role = business.permission_roles.create!(name: "Laundry Viewer Only", permissions: %w[view_towel_balances])
    viewer = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    sign_in viewer

    get root_path
    body = response.body

    expect(body).to match(group_details_regex("laundry", open: false))
    expect(body).to include(laundry_towel_balances_path)
    expect(body).not_to include(laundry_towel_types_path) # requires configure_towel_usage_expectations
  end

  it "expands the Inventory group and highlights the item on an inventory page" do
    get inventory_root_path
    html = response.body
    expect(html).to match(group_details_regex("inventory", open: true))
    expect(html).to include(I18n.t("nav.section_inventory"))
    expect(html).to include("sidebar__nav-item--sub is-active")
  end

  it "expands the Performance group on a performance page" do
    get performance_root_path
    html = response.body
    expect(html).to match(group_details_regex("performance", open: true))
    expect(html).to include("is-active")
  end

  it "works the same under the Arabic locale (RTL)" do
    super_admin.update!(preferred_locale: "ar")
    get inventory_root_path(locale: :ar)
    body = response.body

    expect(body).to include('dir="rtl"')
    expect(body).to match(group_details_regex("inventory", open: true))
    expect(body).to include("sidebar__nav-item--sub is-active")
    expect(body).to include(I18n.t("nav.section_inventory", locale: :ar))
  end

  it "renders correctly under English (LTR) with the same component, no duplicated markup" do
    super_admin.update!(preferred_locale: "en")
    get inventory_root_path
    body = response.body

    expect(body).to include('dir="ltr"')
    expect(body).to match(group_details_regex("inventory", open: true))
    # The group markup for a given key appears exactly once per render.
    expect(body.scan(%(data-sidebar-group-key-value="inventory")).length).to eq(1)
  end

  it "Super Admin continues to see every collapsible group and every link inside them" do
    get root_path
    body = response.body

    GROUPS.each_key { |key| expect(body).to match(group_details_regex(key, open: false)) }
    expect(body).to include(I18n.t("nav.section_administration"))
  end
end
