require "rails_helper"

RSpec.describe "Inventory workspace navigation", type: :request do
  let(:business)    { create(:business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s))
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def doc = Nokogiri::HTML(response.body)
  def rail_hrefs      = doc.css(".ws__rail a.ws__rail-item").map { |a| a["href"] }
  def tab_hrefs       = doc.css(".ws__tabs a.ws__tab").map { |a| a["href"] }
  def more_hrefs      = doc.css(".ws__more-menu a.ws__more-item").map { |a| a["href"] }
  def active_rail_href = doc.css(".ws__rail a.is-active").map { |a| a["href"] }

  ALL_SECTION_PATHS = %i[
    inventory_root_path inventory_products_path inventory_warehouses_path inventory_suppliers_path
    inventory_purchase_requests_path inventory_goods_receipts_path inventory_stock_issues_path
    inventory_stock_transfers_path inventory_stock_adjustments_path inventory_stock_counts_path
    inventory_movements_report_path inventory_reports_path inventory_settings_path
  ].freeze

  describe "for a user with full inventory access" do
    before { sign_in super_admin }

    it "wraps the page in the workspace with header, breadcrumb and every section" do
      get inventory_root_path
      expect(response).to have_http_status(:ok)

      expect(doc.at_css(".ws__title").text).to eq(I18n.t("nav.inventory_workspace"))
      expect(doc.css(".ws__crumbs li").map { |li| li.text.strip })
        .to eq([ "WorkPulse", I18n.t("nav.inventory_workspace") ])
      expect(rail_hrefs).to eq(ALL_SECTION_PATHS.map { |p| send(p) })
      expect(active_rail_href).to eq([ inventory_root_path ])
    end

    it "offers the same sections on mobile — primary tabs plus a More menu, with no duplicates" do
      get inventory_root_path

      expect(tab_hrefs).to eq([ inventory_root_path, inventory_products_path, inventory_purchase_requests_path,
                                inventory_goods_receipts_path, inventory_stock_issues_path, inventory_stock_counts_path ])
      expect(more_hrefs).to eq([ inventory_warehouses_path, inventory_suppliers_path, inventory_stock_transfers_path,
                                 inventory_stock_adjustments_path, inventory_movements_report_path,
                                 inventory_reports_path, inventory_settings_path ])
      expect(tab_hrefs & more_hrefs).to be_empty
    end

    {
      inventory_warehouses_path:        "nav.inventory_warehouses",
      inventory_suppliers_path:         "nav.inventory_suppliers",
      inventory_stock_transfers_path:   "nav.inventory_stock_transfers",
      inventory_stock_adjustments_path: "nav.inventory_stock_adjustments",
      inventory_movements_report_path:  "nav.inventory_movements",
      inventory_reports_path:           "nav.inventory_reports",
      inventory_settings_path:          "nav.inventory_settings"
    }.each do |path_helper, label_key|
      it "on #{path_helper} (a More section) highlights More, names the section on it, and marks it in the menu" do
        get send(path_helper)

        button = doc.at_css(".ws__more-btn")
        expect(button["class"]).to include("is-active")
        expect(button.at_css(".ws__more-label").text.strip).to eq(I18n.t(label_key))
        expect(doc.css(".ws__more-menu a.is-active").map { |a| a["href"] }).to eq([ send(path_helper) ])
        expect(doc.css(".ws__tabs a.is-active")).to be_empty
        # Menu still offers every More section, so the user can jump between them.
        expect(more_hrefs.size).to eq(7)
      end
    end

    it "labels the More button with the current section when that section lives in More" do
      get inventory_stock_transfers_path
      button = doc.at_css(".ws__more-btn")
      expect(button["class"]).to include("is-active")
      expect(button.text).to include(I18n.t("nav.inventory_stock_transfers"))
      expect(doc.at_css(".ws__more-menu a.is-active")["href"]).to eq(inventory_stock_transfers_path)
    end

    {
      inventory_brands_path:             :inventory_settings_path,
      inventory_product_categories_path: :inventory_settings_path,
      inventory_movements_report_path:   :inventory_movements_report_path,
      inventory_current_stock_report_path: :inventory_reports_path,
      new_inventory_stock_issue_path:    :inventory_stock_issues_path,
      new_inventory_goods_receipt_path:  :inventory_goods_receipts_path
    }.each do |page, section|
      it "marks #{section} active on #{page}" do
        get send(page)
        expect(response).to have_http_status(:ok)
        expect(active_rail_href).to eq([ send(section) ])
      end
    end

    it "links the section crumb back to its list on a deep page" do
      get new_inventory_stock_issue_path
      crumbs = doc.css(".ws__crumbs li")
      expect(crumbs.last.at_css("a")["href"]).to eq(inventory_stock_issues_path)
    end

    it "opens every section by direct URL, inside the workspace" do
      ALL_SECTION_PATHS.each do |path_helper|
        get send(path_helper)
        expect(response).to have_http_status(:ok), "#{path_helper} returned #{response.status}"
        expect(doc.at_css(".ws .ws__content")).to be_present, "#{path_helper} is not inside the workspace"
      end
    end

    it "does not render the workspace outside inventory" do
      get root_path
      expect(response.body).not_to include("ws__")
    end

    it "renders Arabic labels under RTL" do
      super_admin.update!(preferred_locale: "ar")
      get inventory_root_path(locale: :ar)
      expect(response.body).to include('dir="rtl"')
      expect(doc.at_css(".ws__title").text).to eq(I18n.t("nav.inventory_workspace", locale: :ar))
      expect(doc.at_css(".ws__more-btn").text).to include(I18n.t("workspace.more", locale: :ar))
    end

    it "renders the settings hub linking to categories and brands" do
      get inventory_settings_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(inventory_product_categories_path, inventory_brands_path)
    end
  end

  describe "permission filtering" do
    it "shows a reports-only user just the sections they can open" do
      sign_in user_with(:view_inventory_reports)
      get inventory_root_path

      expect(response).to have_http_status(:ok)
      expect(rail_hrefs).to eq([ inventory_root_path, inventory_movements_report_path, inventory_reports_path ])
      expect(response.body).not_to include(%(href="#{inventory_products_path}"))
      expect(response.body).not_to include(%(href="#{inventory_settings_path}"))
    end

    it "refuses the settings hub to a user who cannot view categories or brands" do
      sign_in user_with(:view_inventory_reports)
      get inventory_settings_path
      expect(response).not_to have_http_status(:ok)
    end

    it "keeps the main sidebar entry hidden from users without inventory access" do
      sign_in user_with(:view_dashboard)
      get root_path
      expect(response.body).not_to include(%(href="#{inventory_root_path}"))
    end
  end
end
