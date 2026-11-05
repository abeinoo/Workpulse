require "rails_helper"

# Salary Payment Hold through the UI: placing / releasing on the employee page,
# server-side authorization and business isolation, the payroll period and
# entry pages (statuses, held / payable amounts, Pay Released Salary), Mark Paid
# over HTTP, and EN / AR rendering.
RSpec.describe "Salary Payment Holds", type: :request do
  around { |ex| travel_to(Time.zone.local(2026, 11, 10, 12, 0, 0)) { ex.run } }

  let(:business)    { create(:business, timezone: "UTC") }
  let!(:accountant) { create(:user, :accountant, business: business) }
  let(:hr) do
    role = business.permission_roles.create!(
      name: "HR", permissions: %w[view_employees view_payroll view_salary_payment_holds manage_salary_payment_holds],
      permission_scopes: { "view_employees" => "business", "view_payroll" => "business",
                           "view_salary_payment_holds" => "business", "manage_salary_payment_holds" => "business" }
    )
    create(:user, business: business, permission_role: role)
  end
  let(:viewer) do
    role = business.permission_roles.create!(
      name: "Finance view", permissions: %w[view_employees view_payroll view_salary_payment_holds],
      permission_scopes: { "view_employees" => "business", "view_payroll" => "business",
                           "view_salary_payment_holds" => "business" }
    )
    create(:user, business: business, permission_role: role)
  end
  let(:ahmed) { create(:user, business: business, first_name: "Ahmed", last_name: "Held") }
  let(:sara)  { create(:user, business: business, first_name: "Sara", last_name: "Normal") }

  let(:october) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 10, status: :finalized).tap do |period|
      create(:payroll_entry, payroll_period: period, user: ahmed, net_salary: 5_000)
      create(:payroll_entry, payroll_period: period, user: sara,  net_salary: 4_000)
    end
  end

  def place_hold(as: hr, user: ahmed)
    sign_in as
    post admin_user_salary_payment_holds_path(user),
         params: { reason: "missing_documents", effective_from: "2026-10-01", notes: "Contract not signed" }
  end

  def page = Nokogiri::HTML(response.body)
  def entry_of(user) = october.payroll_entries.find_by!(user: user)

  describe "the employee page" do
    it "lets HR place a hold, then shows it with a release form" do
      place_hold
      expect(response).to redirect_to(admin_user_path(ahmed))
      expect(SalaryPaymentHold.active.sole).to have_attributes(user_id: ahmed.id, created_by_id: hr.id, notes: "Contract not signed")

      get admin_user_path(ahmed)
      expect(page.at_css("[data-testid='salary-hold-status']").text).to include(I18n.t("salary_payment_holds.status.on_hold"))
      expect(page.at_css("[data-testid='salary-hold-active']").text).to include(I18n.t("salary_payment_holds.reasons.missing_documents"))
      expect(page.at_css("[data-testid='salary-hold-release-form']")).to be_present
    end

    it "lets HR release it — recorded, and the history stays" do
      place_hold
      hold = SalaryPaymentHold.sole
      patch release_admin_salary_payment_hold_path(hold), params: { release_reason: "Signed" }
      expect(hold.reload).to have_attributes(released_by_id: hr.id, release_reason: "Signed")

      get admin_user_path(ahmed)
      expect(page.at_css("[data-testid='salary-hold-status']").text).to include(I18n.t("salary_payment_holds.status.normal"))
      expect(page.at_css("[data-testid='salary-hold-#{hold.id}']").text).to include("Signed")
      expect(page.at_css("[data-testid='salary-hold-create-form']")).to be_present
    end

    it "shows a view-only user the hold without any form" do
      place_hold
      sign_in viewer
      get admin_user_path(ahmed)
      expect(page.at_css("[data-testid='salary-hold-active']")).to be_present
      expect(page.at_css("[data-testid='salary-hold-release-form']")).to be_nil
      expect(page.at_css("[data-testid='salary-hold-create-form']")).to be_nil
    end

    it "shows nothing to a user without the hold permission" do
      place_hold
      payroll_only = business.permission_roles.create!(name: "P", permissions: %w[view_employees view_payroll],
                                                       permission_scopes: { "view_employees" => "business", "view_payroll" => "business" })
      sign_in create(:user, business: business, permission_role: payroll_only)
      get admin_user_path(ahmed)
      expect(page.at_css("[data-testid='salary-hold-panel']")).to be_nil
    end

    it "renders in Arabic" do
      place_hold
      hr.update!(preferred_locale: "ar")
      get admin_user_path(ahmed)
      expect(response.body).to include("إيقاف صرف الراتب")
      expect(response.body).not_to include("translation missing")
    end
  end

  describe "11. authorization, server side" do
    it "refuses a view-only user placing or releasing a hold" do
      place_hold(as: viewer)
      expect(response).to redirect_to(root_path)
      expect(SalaryPaymentHold.count).to eq(0)

      place_hold
      hold = SalaryPaymentHold.sole
      sign_in viewer
      patch release_admin_salary_payment_hold_path(hold)
      expect(hold.reload).to be_active
    end

    it "refuses a cashier / plain employee" do
      place_hold(as: create(:user, business: business))
      expect(SalaryPaymentHold.count).to eq(0)
    end

    it "refuses HR acting on their own salary" do
      place_hold(user: hr)
      expect(SalaryPaymentHold.count).to eq(0)
    end

    it "12. never reaches another business's employee or hold" do
      outsider = create(:user)
      place_hold(user: outsider)
      expect(response).to have_http_status(:not_found)

      other_hold = create(:salary_payment_hold)
      sign_in hr # the test session drops the sign-in after a 404 response
      patch release_admin_salary_payment_hold_path(other_hold)
      expect(response).to have_http_status(:not_found)
      expect(other_hold.reload).to be_active
    end
  end

  describe "the payroll period and entry pages" do
    before do
      october
      place_hold
    end

    it "2. keeps the held employee in the list, marked on hold, with held and payable totals" do
      sign_in accountant
      get payroll_period_path(october)
      expect(page.at_css("[data-testid='salary-hold-badge-#{entry_of(ahmed).id}']").text)
        .to include(I18n.t("salary_payment_holds.entry_states.on_hold"))
      expect(page.at_css("[data-testid='salary-hold-badge-#{entry_of(sara).id}']")).to be_nil
      expect(page.at_css("[data-testid='salary-hold-summary-held']").text).to include("5,000")
      expect(page.at_css("[data-testid='salary-hold-summary-payable']").text).to include("4,000")
      expect(page.at_css("[data-testid='bank-transfer-held']").text).to include("5,000")
    end

    it "Mark Paid over HTTP pays the period and withholds the held entry; payment after release is recorded" do
      sign_in accountant
      patch mark_paid_payroll_period_path(october)
      expect(october.reload).to be_paid
      expect(SalaryPaymentWithholding.sole.payroll_entry).to eq(entry_of(ahmed))

      get payroll_period_payroll_entry_path(october, entry_of(ahmed))
      expect(page.at_css("[data-testid='entry-salary-hold']").text).to include(I18n.t("salary_payment_holds.entry_states.held"))
      expect(page.at_css("[data-testid='pay-released-salary-form']")).to be_nil

      # Forcing the payment while on hold is refused server side.
      patch pay_released_salary_payroll_period_payroll_entry_path(october, entry_of(ahmed)), params: { disbursement_note: "x" }
      expect(SalaryPaymentWithholding.sole).not_to be_disbursed

      sign_in hr
      patch release_admin_salary_payment_hold_path(SalaryPaymentHold.sole)
      sign_in accountant
      get payroll_period_payroll_entry_path(october, entry_of(ahmed))
      expect(page.at_css("[data-testid='pay-released-salary-form']")).to be_present

      patch pay_released_salary_payroll_period_payroll_entry_path(october, entry_of(ahmed)),
            params: { disbursement_note: "Transfer 991" }
      expect(SalaryPaymentWithholding.sole).to have_attributes(disbursed_by_id: accountant.id, disbursement_note: "Transfer 991")
    end

    it "refuses Pay Released Salary to a user without pay_payroll" do
      sign_in accountant
      patch mark_paid_payroll_period_path(october)
      sign_in hr
      patch release_admin_salary_payment_hold_path(SalaryPaymentHold.sole)

      patch pay_released_salary_payroll_period_payroll_entry_path(october, entry_of(ahmed)), params: { disbursement_note: "x" }
      expect(SalaryPaymentWithholding.sole).not_to be_disbursed
    end

    it "the bank-transfer CSV never contains the held employee" do
      [ ahmed, sara ].each { |u| u.update_columns(identity_card_number: "ID#{u.id}") }
      sign_in accountant
      get export_bank_transfer_payroll_period_path(october)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(sara.full_name)
      expect(response.body).not_to include(ahmed.full_name)
    end

    it "shows the status in Arabic without missing translations" do
      accountant.update!(preferred_locale: "ar")
      sign_in accountant
      get payroll_period_path(october)
      expect(response.body).to include("موظف صرف راتبه موقوف")
      expect(response.body).not_to include("translation missing")
    end
  end
end
