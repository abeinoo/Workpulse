require "rails_helper"

# Finance and Laundry run on the same workspace infrastructure as Inventory
# (WorkspaceHelper + layouts/_workspace) — see
# spec/requests/inventory/workspace_navigation_spec.rb for the shared behaviour.
RSpec.describe "Finance & Laundry workspace navigation", type: :request do
  let(:business)    { create(:business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s))
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def doc = Nokogiri::HTML(response.body)
  def rail_hrefs       = doc.css(".ws__rail a.ws__rail-item").map { |a| a["href"] }
  def tab_hrefs        = doc.css(".ws__tabs a.ws__tab").map { |a| a["href"] }
  def more_hrefs       = doc.css(".ws__more-menu a.ws__more-item").map { |a| a["href"] }
  def active_rail_href = doc.css(".ws__rail a.is-active").map { |a| a["href"] }
  def sidebar_hrefs    = doc.css(".sidebar a.sidebar__nav-item").map { |a| a["href"] }

  FINANCE_PRIMARY = %i[
    finance_root_path finance_expenses_path finance_custody_accounts_path
    finance_balance_requests_path finance_daily_reconciliations_path
  ].freeze
  FINANCE_MORE = %i[
    finance_recurring_expenses_path finance_deposit_verifications_path finance_sales_imports_path
    finance_pos_imports_path finance_reports_path finance_expense_categories_path
    finance_expense_types_path finance_expense_tags_path finance_payment_methods_path
  ].freeze
  LAUNDRY_PRIMARY = %i[
    laundry_root_path laundry_towel_transfers_path laundry_towel_balances_path
    laundry_towel_adjustments_path laundry_reports_branch_consumption_path
  ].freeze
  LAUNDRY_MORE = %i[laundry_reports_cost_summary_path laundry_towel_types_path].freeze

  describe "for a user with full access" do
    before { sign_in super_admin }

    it "shows one entry per workspace in the main sidebar, in order, instead of every module page" do
      get root_path
      expect(sidebar_hrefs).to include(finance_root_path, inventory_root_path, laundry_root_path)
      expect(sidebar_hrefs.index(finance_root_path)).to be < sidebar_hrefs.index(inventory_root_path)
      expect(sidebar_hrefs.index(inventory_root_path)).to be < sidebar_hrefs.index(laundry_root_path)
      expect(sidebar_hrefs).not_to include(finance_expenses_path, laundry_towel_transfers_path)
      expect(response.body).not_to include(%(data-sidebar-group-key-value="finance"))
      expect(response.body).not_to include(%(data-sidebar-group-key-value="laundry"))
    end

    {
      finance: [ FINANCE_PRIMARY, FINANCE_MORE, "nav.section_finance" ],
      laundry: [ LAUNDRY_PRIMARY, LAUNDRY_MORE, "nav.section_laundry" ]
    }.each do |key, (primary, more, title_key)|
      describe "#{key} workspace" do
        it "renders header, breadcrumb, every section in the rail, and the mobile primary/More split" do
          get send(primary.first)
          expect(response).to have_http_status(:ok)
          expect(doc.at_css(".ws.ws--#{key} .ws__title").text).to eq(I18n.t(title_key))
          expect(doc.css(".ws__crumbs li").map { |li| li.text.strip }).to eq([ "WorkPulse", I18n.t(title_key) ])
          expect(rail_hrefs).to match_array((primary + more).map { |p| send(p) })
          expect(tab_hrefs).to eq(primary.map { |p| send(p) })
          expect(more_hrefs).to eq(more.map { |p| send(p) })
        end

        it "opens every section by direct URL inside the workspace, with that section active" do
          (primary + more).each do |path_helper|
            get send(path_helper)
            expect(response).to have_http_status(:ok), "#{path_helper} returned #{response.status}"
            expect(doc.at_css(".ws--#{key} .ws__content")).to be_present, "#{path_helper} is not in the workspace"
            expect(active_rail_href).to eq([ send(path_helper) ]), "#{path_helper} is not the active section"
            expect(sidebar_hrefs & [ send(primary.first) ]).to be_present
            expect(doc.at_css(".sidebar a.sidebar__nav-item.is-active")["href"]).to eq(send(primary.first))
          end
        end

        it "on a More section, marks More active and names the section on it" do
          get send(more.first)
          button = doc.at_css(".ws__more-btn")
          expect(button["class"]).to include("is-active")
          expect(doc.css(".ws__tabs a.is-active")).to be_empty
          expect(doc.css(".ws__more-menu a.is-active").map { |a| a["href"] }).to eq([ send(more.first) ])
          expect(button.at_css(".ws__more-label").text.strip).to eq(doc.at_css(".ws__more-menu a.is-active").text.strip)
        end
      end
    end

    it "maps Finance sub-pages to their section and links the crumb back to it" do
      get new_finance_expense_path
      expect(active_rail_href).to eq([ finance_expenses_path ])
      expect(doc.css(".ws__crumbs li").last.at_css("a")["href"]).to eq(finance_expenses_path)

      get new_finance_bank_statement_path
      expect(active_rail_href).to eq([ finance_deposit_verifications_path ])
    end

    it "maps the towel-type cost-rate page to Towel Types" do
      towel_type = business.towel_types.create!(name: "Bath towel")
      get new_laundry_towel_type_standard_cost_rate_path(towel_type)
      expect(active_rail_href).to eq([ laundry_towel_types_path ])
    end

    it "keeps Laundry Batches out of the navigation but still inside the workspace" do
      get laundry_laundry_batches_path
      expect(response).to have_http_status(:ok)
      expect(doc.at_css(".ws--laundry")).to be_present
      expect(response.body).not_to include(%(class="ws__rail-item is-active))
      expect(rail_hrefs).not_to include(laundry_laundry_batches_path)
    end

    it "renders Arabic titles under RTL" do
      super_admin.update!(preferred_locale: "ar")
      get finance_expenses_path(locale: :ar)
      expect(response.body).to include('dir="rtl"')
      expect(doc.at_css(".ws__title").text).to eq(I18n.t("nav.section_finance", locale: :ar))
      expect(doc.at_css(".ws__more-btn").text).to include(I18n.t("workspace.more", locale: :ar))
    end
  end

  describe "permission filtering" do
    it "shows an expenses-only user Expenses but not Reports, Overview or setup pages, and enters on Expenses" do
      sign_in user_with(:view_expenses)
      get finance_expenses_path
      expect(response).to have_http_status(:ok)

      expect(rail_hrefs).to eq([ finance_expenses_path, finance_recurring_expenses_path, finance_custody_accounts_path ])
      expect(rail_hrefs).not_to include(finance_root_path, finance_reports_path, finance_expense_categories_path)
      # Main sidebar entry opens the first section they can open, not the dashboard they'd be refused.
      expect(doc.at_css(".sidebar a.sidebar__nav-item.is-active")["href"]).to eq(finance_expenses_path)
      get finance_root_path
      expect(response).not_to have_http_status(:ok)
    end

    it "shows setup pages only to users who manage them" do
      sign_in user_with(:view_expenses, :manage_expense_categories)
      get finance_expenses_path
      expect(rail_hrefs).to include(finance_expense_categories_path)
      expect(rail_hrefs).not_to include(finance_expense_types_path, finance_expense_tags_path, finance_payment_methods_path)
    end

    it "shows a reports-only finance user just Reports" do
      sign_in user_with(:view_expense_reports)
      get finance_reports_path
      expect(rail_hrefs).to eq([ finance_reports_path ])
    end

    it "shows a towel viewer the operational sections but not cost reports or Towel Types setup" do
      sign_in user_with(:view_towel_balances)
      get laundry_root_path
      expect(rail_hrefs).to eq([ laundry_root_path, laundry_towel_transfers_path, laundry_towel_balances_path,
                                 laundry_towel_adjustments_path ])
    end

    it "shows a laundry cost-report user only the Overview and the operating-cost report" do
      sign_in user_with(:view_laundry_cost_reports)
      get laundry_reports_cost_summary_path
      expect(response).to have_http_status(:ok)
      expect(rail_hrefs).to eq([ laundry_root_path, laundry_reports_cost_summary_path ])
    end

    it "hides a workspace entirely from users who cannot enter it" do
      sign_in user_with(:view_dashboard)
      get root_path
      expect(sidebar_hrefs).not_to include(finance_root_path, finance_expenses_path, laundry_root_path, inventory_root_path)
      expect(response.body).not_to include(I18n.t("nav.section_workspaces"))
    end
  end
end
