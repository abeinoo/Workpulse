require "rails_helper"

RSpec.describe "Admin::EmployeeObligations", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }

  let(:period) { create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22) }

  let!(:obligation) do
    create(:employee_obligation,
           user: employee, business: business, created_by: owner,
           start_month: 6, start_year: 2026,
           total_amount: 1_500.0, remaining_amount: 1_500.0, installment_amount: 500.0)
  end

  before { sign_in owner }

  describe "GET /admin/employee_obligations/:id/edit" do
    it "renders the edit form when not locked" do
      get edit_admin_employee_obligation_path(obligation)
      expect(response).to have_http_status(:ok)
    end

    it "redirects with an alert once a deduction's period is finalized" do
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period)
      period.update_column(:status, "finalized")

      get edit_admin_employee_obligation_path(obligation)

      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      follow_redirect!
      expect(response.body).to include(I18n.t("admin.employee_obligations.locked_for_edit"))
    end
  end

  describe "PATCH /admin/employee_obligations/:id" do
    it "updates the obligation and recalculates affected payroll" do
      create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: 1.year.ago.to_date)
      Payroll::EntryCalculator.call(period: period, user: employee, business: business)
      expect(ObligationDeduction.where(payroll_period: period)).to be_present

      patch admin_employee_obligation_path(obligation),
            params: { employee_obligation: { start_month: 7, start_year: 2026,
                                              total_amount: 1_500.0, installment_amount: 500.0 } }

      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      expect(obligation.reload.start_month).to eq(7)
      expect(ObligationDeduction.where(payroll_period: period)).to be_empty
    end

    it "refuses the update once a deduction's period is finalized" do
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period)
      period.update_column(:status, "finalized")

      patch admin_employee_obligation_path(obligation),
            params: { employee_obligation: { start_month: 7, start_year: 2026,
                                              total_amount: 1_500.0, installment_amount: 500.0 } }

      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      expect(obligation.reload.start_month).to eq(6)
    end
  end
end
