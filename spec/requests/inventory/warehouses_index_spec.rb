require "rails_helper"

# Warehouses index: a Type column (from warehouse.kind only — NULL is
# "Unclassified"), a Branch column (the warehouse's own branch, through the
# association), and type filter tabs whose counts come from the user's
# accessible warehouses before the filter. Nothing on the page writes.
RSpec.describe "Inventory::Warehouses — index types, branches and filters", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:shubra)   { create(:branch, business: business, name: "Shubra", branch_type: "sales") }
  let(:nasr)     { create(:branch, business: business, name: "Nasr", branch_type: "sales") }

  # Like warehouse #1: predates the warehouse architecture, kind NULL.
  let!(:legacy)  { business.warehouses.create!(name: "المخزن الرئيسي") }
  let!(:central) { business.warehouses.create!(name: "Riyadh Central", kind: "central") }
  let!(:shubra_wh) { provision(shubra) }
  let!(:nasr_wh)   { provision(nasr) }

  def provision(branch) = Branch.transaction { Inventory::BranchWarehouseProvisioning.provision!(branch: branch, actor: owner) }

  def body = CGI.unescapeHTML(response.body)
  def rows = Nokogiri::HTML(response.body).css("table tbody tr")
  def row_for(warehouse) = rows.find { |tr| tr.at_css("td a")&.text == warehouse.name }
  def cell(warehouse, label) = row_for(warehouse).css("td").find { |td| td["data-label"] == label }&.text&.strip
  def type_of(warehouse)   = cell(warehouse, I18n.t("inventory.warehouses.kind"))
  def branch_of(warehouse) = cell(warehouse, I18n.t("inventory.warehouses.branch"))
  def listed_names = rows.map { |tr| tr.at_css("td a").text }
  def tab(key) = Nokogiri::HTML(response.body).at_css(%(.filter-tab[data-kind-filter="#{key}"]))
  def tab_count(key) = tab(key).at_css(".badge").text.strip.to_i

  def visit_index(as: owner, **params)
    sign_in as
    get inventory_warehouses_path(params)
    expect(response).to have_http_status(:ok)
  end

  describe "type column" do
    before { visit_index }

    it "shows Central, Branch and Unclassified from the stored kind" do
      expect(type_of(central)).to eq("Central")
      expect(type_of(shubra_wh)).to eq("Branch")
      expect(type_of(legacy)).to eq("Unclassified")
    end

    it "leaves the unclassified warehouse unclassified (the page writes nothing)" do
      expect(legacy.reload.kind).to be_nil
    end
  end

  it "never infers the type from the name" do
    look_alike = business.warehouses.create!(name: "Shubra – المخزن 2", kind: "central")
    unclassified_look_alike = business.warehouses.create!(name: "Nasr – المخزن (old)")

    visit_index
    expect(type_of(look_alike)).to eq("Central")
    expect(branch_of(look_alike)).to eq("—")
    expect(type_of(unclassified_look_alike)).to eq("Unclassified")
    expect(branch_of(unclassified_look_alike)).to eq("—")
  end

  describe "branch column" do
    it "shows the associated branch name for branch warehouses and — otherwise" do
      visit_index
      expect(branch_of(shubra_wh)).to eq("Shubra")
      expect(branch_of(nasr_wh)).to eq("Nasr")
      expect(branch_of(central)).to eq("—")
      expect(branch_of(legacy)).to eq("—")
    end

    it "marks an inactive branch" do
      nasr.update_column(:active, false)
      visit_index
      expect(branch_of(nasr_wh)).to eq("Nasr (Inactive)")
      expect(branch_of(shubra_wh)).to eq("Shubra")
    end

    it "follows the association, not the warehouse name" do
      shubra.update_column(:name, "Shubra Renamed")
      visit_index
      expect(branch_of(shubra_wh)).to eq("Shubra Renamed")
    end
  end

  describe "filter tabs" do
    it "lists every warehouse in name order with no filter, All active" do
      visit_index
      expect(listed_names).to eq([ "Nasr – المخزن", "Riyadh Central", "Shubra – المخزن", "المخزن الرئيسي" ])
      expect(tab("all")["class"]).to include("filter-tab--active")
      expect(tab("all")["aria-current"]).to eq("page")
      %w[central branch unclassified].each { |k| expect(tab(k)["class"]).not_to include("filter-tab--active") }
    end

    {
      "central"      => [ "Riyadh Central" ],
      "branch"       => [ "Nasr – المخزن", "Shubra – المخزن" ],
      "unclassified" => [ "المخزن الرئيسي" ]
    }.each do |kind, names|
      it "kind=#{kind} lists only that type and marks its tab active" do
        visit_index(kind: kind)
        expect(listed_names).to eq(names)
        expect(tab(kind)["class"]).to include("filter-tab--active")
        expect(tab("all")["class"]).not_to include("filter-tab--active")
      end
    end

    [ "laundry", "BRANCH", "all", "", "central' OR 1=1", %w[central branch] ].each do |value|
      it "treats kind=#{value.inspect} as All" do
        visit_index(kind: value)
        expect(listed_names.size).to eq(4)
        expect(tab("all")["class"]).to include("filter-tab--active")
      end
    end

    it "shows the same scope-wide counts under every filter" do
      [ nil, "central", "branch", "unclassified", "bogus" ].each do |kind|
        visit_index(**(kind ? { kind: kind } : {}))
        expect(%w[all central branch unclassified].index_with { |k| tab_count(k) })
          .to eq("all" => 4, "central" => 1, "branch" => 2, "unclassified" => 1)
      end
    end

    it "links each tab to its filter" do
      visit_index
      expect(tab("all")["href"]).to eq(inventory_warehouses_path)
      expect(tab("branch")["href"]).to eq(inventory_warehouses_path(kind: "branch"))
    end
  end

  describe "access scope" do
    let(:assigned) do
      user_with_stock_permissions(business, :view_inventory).tap { |u| u.assigned_warehouses << shubra_wh }
    end

    it "lists and counts only the user's accessible warehouses, under every filter" do
      [ nil, "branch", "central", "unclassified" ].each do |kind|
        visit_index(as: assigned, **(kind ? { kind: kind } : {}))
        expect(%w[all central branch unclassified].index_with { |k| tab_count(k) })
          .to eq("all" => 1, "central" => 0, "branch" => 1, "unclassified" => 0)
        expect(body).not_to include("Riyadh Central", "المخزن الرئيسي", "Nasr")
      end
      visit_index(as: assigned, kind: "branch")
      expect(listed_names).to eq([ "Shubra – المخزن" ])
    end

    it "never shows another business's warehouses or branch names" do
      other = create(:business)
      other_owner = create(:user, :owner, business: other)
      foreign_branch = create(:branch, business: other, name: "Foreign Branch", branch_type: "sales")
      Branch.transaction { Inventory::BranchWarehouseProvisioning.provision!(branch: foreign_branch, actor: other_owner) }
      other.warehouses.create!(name: "Foreign Central", kind: "central")

      [ nil, "central", "branch", "unclassified" ].each do |kind|
        visit_index(**(kind ? { kind: kind } : {}))
        expect(body).not_to include("Foreign Branch", "Foreign Central")
        expect(tab_count("all")).to eq(4)
      end
    end

    it "shows no branch for an inconsistent cross-business link" do
      foreign_branch = create(:branch, business: create(:business), name: "Foreign Branch", branch_type: "sales")
      shubra_wh.update_columns(branch_id: foreign_branch.id) # an impossible state, forced past every validation

      visit_index
      expect(branch_of(shubra_wh)).to eq("—")
      expect(body).not_to include("Foreign Branch")
    end
  end

  describe "authorization (unchanged)" do
    it "still refuses a user without view_inventory or manage_inventory" do
      sign_in user_with_stock_permissions(business, :view_employee_balances)
      get inventory_warehouses_path(kind: "branch")
      expect(response).to redirect_to(root_path)
    end

    it "shows Add only to those who may create, and Edit only with manage_inventory" do
      viewer = user_with_stock_permissions(business, :view_inventory)
      visit_index(as: viewer)
      expect(body).not_to include(%(href="#{new_inventory_warehouse_path}"))
      expect(body).not_to include(edit_inventory_warehouse_path(central))

      manager = user_with_stock_permissions(business, :view_inventory, :manage_inventory)
      visit_index(as: manager)
      expect(body).not_to include(%(href="#{new_inventory_warehouse_path}"))
      expect(body).to include(edit_inventory_warehouse_path(central))

      visit_index(as: owner)
      expect(body).to include(%(href="#{new_inventory_warehouse_path}"), edit_inventory_warehouse_path(central))
    end
  end

  describe "empty states" do
    it "keeps the existing empty state (and no tabs) when the user has no warehouses" do
      empty_business = create(:business)
      visit_index(as: create(:user, :owner, business: empty_business))
      expect(body).to include(I18n.t("inventory.warehouses.empty"))
      expect(response.body).not_to include("filter-tabs")
    end

    it "shows the filter's own empty message, with the tabs, when nothing matches" do
      legacy_free = create(:business)
      only_owner = create(:user, :owner, business: legacy_free)
      legacy_free.warehouses.create!(name: "Only Central", kind: "central")

      visit_index(as: only_owner, kind: "unclassified")
      expect(body).to include(I18n.t("inventory.warehouses.empty_for_kind"))
      expect(body).not_to include(I18n.t("inventory.warehouses.empty"))
      expect(tab_count("all")).to eq(1)
      expect(tab_count("unclassified")).to eq(0)
      expect(rows).to be_empty
    end
  end

  it "renders in Arabic" do
    owner.update!(preferred_locale: "ar")
    nasr.update_column(:active, false)
    visit_index

    I18n.with_locale(:ar) do
      expect(body).to include(I18n.t("inventory.warehouses.kind"), I18n.t("inventory.warehouses.branch"),
                              I18n.t("inventory.warehouses.filters.all"))
      expect(type_of(legacy)).to eq("غير مصنف")
      expect(type_of(central)).to eq("مركزي")
      expect(type_of(shubra_wh)).to eq("فرع")
      expect(branch_of(nasr_wh)).to eq("Nasr (غير نشط)")
    end
  end

  it "runs the same number of queries for 2 or 6 branch warehouses (no N+1)" do
    count_queries = lambda do
      queries = 0
      callback = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get inventory_warehouses_path }
      queries
    end

    sign_in owner
    get inventory_warehouses_path # warm up
    baseline = count_queries.call

    4.times { |i| provision(create(:branch, business: business, name: "Extra #{i}", branch_type: "sales")) }
    expect(count_queries.call).to eq(baseline)
  end
end
