require "rails_helper"

# Attendance & Shifts and Performance run on the same workspace infrastructure
# as Inventory / Finance / Laundry (WorkspaceHelper + layouts/_workspace), but
# their entries sit in the main sidebar's Employees group. Attendance pages span
# the root and admin namespaces; Evaluation Templates keep their /admin URL.
RSpec.describe "Attendance & Performance workspace navigation", type: :request do
  let(:business)    { create(:business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }

  def user_with(*permissions, workspace: "management")
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s),
                                             workspace: workspace)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def doc = Nokogiri::HTML(response.body)
  def rail_hrefs       = doc.css(".ws__rail a.ws__rail-item").map { |a| a["href"] }
  def tab_hrefs        = doc.css(".ws__tabs a.ws__tab").map { |a| a["href"] }
  def more_hrefs       = doc.css(".ws__more-menu a.ws__more-item").map { |a| a["href"] }
  def active_rail_href = doc.css(".ws__rail a.is-active").map { |a| a["href"] }
  def sidebar_hrefs    = doc.css(".sidebar a.sidebar__nav-item").map { |a| a["href"] }
  def sidebar_active   = doc.css(".sidebar a.sidebar__nav-item.is-active").map { |a| a["href"] }

  ATTENDANCE_PRIMARY = %i[attendance_records_path shift_assignments_path admin_shifts_path].freeze
  ATTENDANCE_MORE    = %i[admin_shift_rule_profiles_path admin_biometric_punch_logs_path].freeze
  PERFORMANCE_PRIMARY = %i[performance_root_path performance_observations_path performance_reviews_path].freeze
  PERFORMANCE_MORE    = %i[performance_reports_path admin_evaluation_templates_path].freeze

  describe "for a user with full access" do
    before { sign_in super_admin }

    it "shows the two workspaces as single entries under Employees, not their pages" do
      get root_path
      employees = doc.css('.sidebar [data-sidebar-group-key-value="employees"] a.sidebar__nav-item--workspace')
      expect(employees.map { |a| a["href"] }).to eq([ attendance_records_path, performance_root_path ])
      expect(employees.css(".sidebar__group-chevron, summary")).to be_empty
      expect(sidebar_hrefs).not_to include(admin_shifts_path, shift_assignments_path, admin_shift_rule_profiles_path,
                                           admin_biometric_punch_logs_path, performance_observations_path,
                                           performance_reviews_path, performance_reports_path,
                                           admin_evaluation_templates_path)
      expect(response.body).not_to include(%(data-sidebar-group-key-value="attendance"))
      expect(response.body).not_to include(%(data-sidebar-group-key-value="performance"))
      # The general Workspaces group is unchanged.
      expect(doc.css('.sidebar [data-sidebar-group-key-value="workspaces"] a').map { |a| a["href"] })
        .to eq([ finance_root_path, inventory_root_path, laundry_root_path ])
    end

    {
      attendance:  [ ATTENDANCE_PRIMARY,  ATTENDANCE_MORE,  "nav.section_attendance_shifts" ],
      performance: [ PERFORMANCE_PRIMARY, PERFORMANCE_MORE, "nav.section_performance" ]
    }.each do |key, (primary, more, title_key)|
      describe "#{key} workspace" do
        it "renders header, every section in the rail, and the mobile primary/More split" do
          get send(primary.first)
          expect(response).to have_http_status(:ok)
          expect(doc.at_css(".ws.ws--#{key} .ws__title").text).to eq(I18n.t(title_key))
          expect(rail_hrefs).to match_array((primary + more).map { |p| send(p) })
          expect(tab_hrefs).to eq(primary.map { |p| send(p) })
          expect(more_hrefs).to eq(more.map { |p| send(p) })
        end

        it "opens every section by its existing URL inside the workspace, with that section and the sidebar entry active" do
          (primary + more).each do |path_helper|
            get send(path_helper)
            expect(response).to have_http_status(:ok), "#{path_helper} returned #{response.status}"
            expect(doc.at_css(".ws--#{key} .ws__content")).to be_present, "#{path_helper} is not in the workspace"
            expect(active_rail_href).to eq([ send(path_helper) ]), "#{path_helper} is not the active section"
            expect(sidebar_active).to eq([ send(primary.first) ])
          end
        end

        it "on a More section, marks More active and names the section on it" do
          get send(more.first)
          button = doc.at_css(".ws__more-btn")
          expect(button["class"]).to include("is-active")
          expect(doc.css(".ws__tabs a.is-active")).to be_empty
          expect(button.at_css(".ws__more-label").text.strip).to eq(doc.at_css(".ws__more-menu a.is-active").text.strip)
        end
      end
    end

    it "maps attendance sub-pages to their section" do
      get new_admin_shift_path
      expect(active_rail_href).to eq([ admin_shifts_path ])
      get admin_shift_templates_path
      expect(active_rail_href).to eq([ shift_assignments_path ])
      get admin_attendance_records_path
      expect(active_rail_href).to eq([ attendance_records_path ])
    end

    it "maps performance sub-pages to their section" do
      get new_performance_observation_path
      expect(active_rail_href).to eq([ performance_observations_path ])
      get new_admin_evaluation_template_path
      expect(active_rail_href).to eq([ admin_evaluation_templates_path ])
      get performance_trend_report_path
      expect(active_rail_href).to eq([ performance_reports_path ])
    end

    it "leaves the rest of /admin outside any workspace" do
      get admin_settings_path
      expect(doc.at_css(".ws")).to be_nil
    end

    it "renders Arabic titles under RTL" do
      super_admin.update!(preferred_locale: "ar")
      get performance_reports_path(locale: :ar)
      expect(response.body).to include('dir="rtl"')
      expect(doc.at_css(".ws__title").text).to eq(I18n.t("nav.section_performance", locale: :ar))
      expect(doc.at_css(".ws__more-label").text.strip).to eq(I18n.t("nav.performance_reports", locale: :ar))
      get admin_shifts_path(locale: :ar)
      expect(doc.at_css(".ws__title").text).to eq(I18n.t("nav.section_attendance_shifts", locale: :ar))
    end
  end

  describe "permission filtering" do
    it "shows a shift assigner only Shift Assignments, and enters Attendance there" do
      sign_in user_with(:view_shifts, :assign_shifts)
      get root_path
      entry = doc.at_css(".sidebar a.sidebar__nav-item--workspace")
      expect(entry["href"]).to eq(shift_assignments_path)

      get shift_assignments_path
      expect(rail_hrefs).to eq([ shift_assignments_path ])
    end

    it "shows a monthly-review viewer only Monthly Reviews in Performance" do
      sign_in user_with(:view_monthly_reviews)
      get performance_reviews_path
      expect(rail_hrefs).to eq([ performance_reviews_path ])
      expect(doc.at_css(".sidebar a.sidebar__nav-item--workspace.is-active")["href"]).to eq(performance_reviews_path)
    end

    it "shows Evaluation Templates only to users who manage them" do
      sign_in user_with(:view_performance_dashboard)
      get performance_root_path
      expect(rail_hrefs).to eq([ performance_root_path ])
      expect(response.body).not_to include(admin_evaluation_templates_path)
    end

    it "hides both entries from users who can open no page inside them" do
      sign_in user_with(:view_payroll)
      get root_path
      expect(doc.css(".sidebar a.sidebar__nav-item--workspace")).to be_empty
      expect(sidebar_hrefs).not_to include(attendance_records_path, performance_root_path)
    end

    it "keeps staff views unwrapped (My attendance / My reviews stay plain pages)" do
      staff = user_with(:view_monthly_reviews, workspace: "employee")
      sign_in staff
      get attendance_records_path
      expect(response).to have_http_status(:ok)
      expect(doc.at_css(".ws")).to be_nil
      get performance_reviews_path
      expect(doc.at_css(".ws")).to be_nil
    end
  end
end
