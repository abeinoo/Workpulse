require "rails_helper"

RSpec.describe "Dashboard birthdays", type: :request do
  # Business day 2026-09-29 in Riyadh (start hour 6 → 10:00 local is well inside it).
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6) }
  let(:now)      { Time.utc(2026, 9, 29, 7, 0) }
  let(:birthday) { Date.new(1994, 9, 29) }

  let(:employee) do
    create(:user, business: business, first_name: "Sara", last_name: "Nasser", preferred_locale: "en")
  end

  let(:celebration_title) { "Happy Birthday, Sara!" }

  around { |ex| travel_to(now) { ex.run } }

  # Real (memory) cache so the once-per-day marker actually persists across requests.
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  def dashboard_html
    get root_path
    expect(response).to have_http_status(:ok)
    response.body
  end

  # Text of the team birthdays strip only — the manager's roster elsewhere on
  # the dashboard legitimately lists the same employees.
  def birthday_strip_text
    Nokogiri::HTML(dashboard_html).at_css(".birthday-strip")&.text.to_s.squish
  end

  # ── Employee: own celebration ────────────────────────────────────────────
  describe "employee celebration" do
    before { sign_in employee }

    it "shows the celebration and greeting badge on the employee's birthday" do
      employee.update!(date_of_birth: birthday)
      html = dashboard_html

      expect(html).to include("birthday-dialog")
      expect(html).to include(celebration_title)
      expect(html).to include(I18n.t("dashboard.birthday.greeting_badge", locale: :en))
    end

    it "shows nothing the day before or after the birthday" do
      employee.update!(date_of_birth: birthday + 1)
      expect(dashboard_html).not_to include("birthday-dialog")

      employee.update!(date_of_birth: birthday - 1)
      expect(dashboard_html).not_to include("birthday-dialog")
    end

    it "shows nothing when the employee has no birth date" do
      html = dashboard_html
      expect(html).not_to include("birthday-dialog")
      expect(html).not_to include("birthday-badge")
    end

    it "does not reappear on reload once seen that day, but the badge stays" do
      employee.update!(date_of_birth: birthday)
      expect(dashboard_html).to include("birthday-dialog")

      post birthday_celebration_path
      expect(response).to have_http_status(:no_content)

      html = dashboard_html
      expect(html).not_to include("birthday-dialog")
      expect(html).to include("birthday-badge")

      travel 10.hours # still the same business day (before the 06:00 rollover)
      expect(dashboard_html).not_to include("birthday-dialog")
    end

    it "becomes eligible again on the next birthday" do
      employee.update!(date_of_birth: birthday)
      dashboard_html
      post birthday_celebration_path

      travel_to(now + 1.year)
      expect(dashboard_html).to include("birthday-dialog")
    end

    it "ignores an acknowledgement posted on a non-birthday" do
      employee.update!(date_of_birth: birthday + 1)
      post birthday_celebration_path
      expect(response).to have_http_status(:no_content)

      travel_to(now + 1.day)
      expect(dashboard_html).to include("birthday-dialog")
    end

    it "does not celebrate another employee's birthday or list it" do
      create(:user, business: business, first_name: "Omar", last_name: "Adel", date_of_birth: birthday)
      html = dashboard_html

      expect(html).not_to include("birthday-dialog")
      expect(html).not_to include("birthday-strip")
      expect(html).not_to include("Omar Adel")
    end
  end

  # ── Business timezone / business-day boundaries ──────────────────────────
  describe "business-day correctness" do
    before do
      employee.update!(date_of_birth: birthday)
      sign_in employee
    end

    it "uses the business timezone, not UTC (01:30 Riyadh on the 29th is still the 28th in UTC)" do
      business.update!(business_day_start_hour: 0)
      travel_to(Time.utc(2026, 9, 28, 22, 30))
      expect(dashboard_html).to include("birthday-dialog")
    end

    it "waits for the business-day rollover hour (04:00 Riyadh with a 06:00 start is still the 28th)" do
      travel_to(Time.utc(2026, 9, 29, 1, 0))
      expect(dashboard_html).not_to include("birthday-dialog")
    end

    it "stays active until the next business day starts (03:00 Riyadh on the 30th)" do
      travel_to(Time.utc(2026, 9, 30, 0, 0))
      expect(dashboard_html).to include("birthday-dialog")
    end
  end

  # ── Manager: team birthdays ──────────────────────────────────────────────
  describe "manager team birthdays" do
    let(:manager)        { create(:user, :branch_manager, business: business, preferred_locale: "en") }
    let(:managed_branch) { Branch.find_by!(branch_manager_id: manager.id) }
    let(:other_branch)   { create(:branch, business: business, name: "Shubra") }

    def assign(user, branch)
      create(:shift_assignment, business: business, user: user, branch: branch,
                                effective_from: Date.new(2026, 6, 1))
    end

    let!(:ahmed) do
      create(:user, business: business, first_name: "Ahmed", last_name: "Mohamed", date_of_birth: Date.new(1990, 9, 29))
        .tap { |u| assign(u, managed_branch) }
    end
    let!(:mohamed) do
      create(:user, business: business, first_name: "Mohamed", last_name: "Ali", date_of_birth: Date.new(2000, 9, 29))
        .tap { |u| assign(u, managed_branch) }
    end
    let!(:outsider) do
      create(:user, business: business, first_name: "Karim", last_name: "Hassan", date_of_birth: Date.new(1988, 9, 29))
        .tap { |u| assign(u, other_branch) }
    end
    let!(:not_today) do
      create(:user, business: business, first_name: "Laila", last_name: "Fathy", date_of_birth: Date.new(1990, 9, 30))
        .tap { |u| assign(u, managed_branch) }
    end

    before { sign_in manager }

    it "lists every authorized employee with a birthday today, with their branch" do
      text = birthday_strip_text

      expect(text).to include(I18n.t("dashboard.birthday.team_title", locale: :en))
      expect(text).to include("Ahmed Mohamed", "Mohamed Ali", managed_branch.name)
      expect(text).to include(I18n.t("dashboard.birthday.team_count", count: 2, locale: :en))
    end

    it "does not reveal birthdays of employees outside the manager's scope" do
      html = dashboard_html
      expect(html).not_to include("Karim Hassan")
      expect(html).not_to include("Shubra")
    end

    it "does not list employees whose birthday is not today" do
      expect(birthday_strip_text).not_to include("Laila Fathy")
    end

    it "hides the section entirely when nobody has a birthday today" do
      travel_to(now + 2.days)
      expect(dashboard_html).not_to include("birthday-strip")
    end

    it "does not show the manager's own celebration for the team's birthdays" do
      expect(dashboard_html).not_to include("birthday-dialog")
    end

    it "shows the whole business to an owner" do
      business.update!(owner: manager)
      expect(birthday_strip_text).to include("Ahmed Mohamed", "Mohamed Ali", "Karim Hassan", "Shubra")
    end
  end

  # ── Arabic / RTL ─────────────────────────────────────────────────────────
  describe "Arabic locale" do
    it "renders the employee celebration in Arabic, right-to-left" do
      employee.update!(date_of_birth: birthday, preferred_locale: "ar")
      sign_in employee
      html = dashboard_html

      expect(html).to include('dir="rtl"')
      expect(html).to include("كل سنة وإنت طيب يا Sara!")
      expect(html).to include("نتمنى لك سنة جديدة سعيدة ومليئة بالنجاح")
    end

    it "renders the manager section heading in Arabic" do
      manager = create(:user, :branch_manager, business: business, preferred_locale: "ar")
      branch  = Branch.find_by!(branch_manager_id: manager.id)
      create(:shift_assignment, business: business, branch: branch, effective_from: Date.new(2026, 6, 1),
                                user: create(:user, business: business, date_of_birth: birthday))
      sign_in manager

      expect(dashboard_html).to include("أعياد ميلاد اليوم", 'dir="rtl"')
    end
  end
end
