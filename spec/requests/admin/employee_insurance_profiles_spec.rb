require "rails_helper"

RSpec.describe "Admin::EmployeeInsuranceProfiles", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }

  before { sign_in owner }

  def period(year:, month:, status:)
    create(:payroll_period, business: business, period_year: year, period_month: month,
           working_days: 22, status: status)
  end

  # ERB auto-escapes rendered output (e.g. "employee's" -> "employee&#39;s"),
  # so comparisons against I18n.t must escape the same way.
  def notice_html(key)
    CGI.escapeHTML(I18n.t("insurance.payroll_notice.#{key}"))
  end

  describe "GET /admin/users/:user_id/employee_insurance_profile/edit" do
    it "shows no payroll notice when the employee has never appeared in a payroll period" do
      get edit_admin_user_employee_insurance_profile_path(employee)

      expect(response.body).not_to include(notice_html(:active))
      expect(response.body).not_to include(notice_html(:finalized))
      expect(response.body).not_to include(notice_html(:mixed))
    end

    it "shows the active notice when exactly one non-finalized period has an entry for them" do
      create(:payroll_entry, user: employee, payroll_period: period(year: 2026, month: 6, status: "draft"))

      get edit_admin_user_employee_insurance_profile_path(employee)

      expect(response.body).to include(notice_html(:active))
    end

    it "shows the active notice even when older finalized periods also exist" do
      create(:payroll_entry, user: employee, payroll_period: period(year: 2026, month: 5, status: "paid"))
      create(:payroll_entry, user: employee, payroll_period: period(year: 2026, month: 6, status: "under_review"))

      get edit_admin_user_employee_insurance_profile_path(employee)

      expect(response.body).to include(notice_html(:active))
    end

    it "shows the finalized warning when every period they appear in is finalized or paid" do
      create(:payroll_entry, user: employee, payroll_period: period(year: 2026, month: 6, status: "finalized"))

      get edit_admin_user_employee_insurance_profile_path(employee)

      expect(response.body).to include(notice_html(:finalized))
    end

    it "shows the mixed notice when more than one non-finalized period has an entry for them" do
      create(:payroll_entry, user: employee, payroll_period: period(year: 2026, month: 6, status: "under_review"))
      create(:payroll_entry, user: employee, payroll_period: period(year: 2026, month: 7, status: "draft"))

      get edit_admin_user_employee_insurance_profile_path(employee)

      expect(response.body).to include(notice_html(:mixed))
    end
  end
end
