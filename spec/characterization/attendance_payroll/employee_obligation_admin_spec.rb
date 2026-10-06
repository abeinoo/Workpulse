require "rails_helper"

# Characterization (Milestone 2 Pilot 2, M1) — CURRENT admin create / edit / show
# behaviour of Employee Obligations, plus the area and self scopes. Index
# filters, sorting, pagination, edit locking and postponement requests are in
# spec/requests/admin/employee_obligations_spec.rb; business, branch, no-scope,
# self-management and create-scope security in spec/requests/security/
# employee_obligations_*_spec.rb (SEC-M2-4, -10, -11).
RSpec.describe "Characterization: employee obligation administration", type: :request do
  around { |example| travel_to(Time.zone.local(2026, 9, 15, 12)) { example.run } }

  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }

  def create_params(**overrides)
    { employee_obligation: { user_id: employee.id, obligation_type: "cash_loan", title: "Laptop loan",
                             total_amount: 1_000, installment_amount: 300,
                             start_month: 10, start_year: 2026 }.merge(overrides) }
  end

  describe "create" do
    before { sign_in owner }

    it "derives the balance and installment count and forces business and creator" do
      post admin_employee_obligations_path, params: create_params(
        business_id: create(:business).id, created_by_id: employee.id, remaining_amount: 5, status: "completed"
      )

      obligation = EmployeeObligation.find_by!(title: "Laptop loan")
      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      expect(flash[:notice]).to eq(I18n.t("admin.employee_obligations.created"))
      expect(obligation).to have_attributes(
        business_id: business.id, created_by_id: owner.id, remaining_amount: 1_000,
        installments_count: 4, status: "active", auto_deduct: true
      )
    end

    it "re-renders the form with 422 and creates nothing for an invalid obligation" do
      expect { post admin_employee_obligations_path, params: create_params(installment_amount: 5_000) }
        .not_to change(EmployeeObligation, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "edit" do
    let(:period) { create(:payroll_period, business: business, period_year: 2026, period_month: 9, working_days: 22) }
    let!(:obligation) do
      create(:employee_obligation, user: employee, business: business, created_by: owner,
                                   start_month: 9, start_year: 2026, total_amount: 1_500, remaining_amount: 1_500,
                                   installment_amount: 500)
    end

    before do
      create(:salary_profile, :monthly, user: employee, base_amount: 8_800, effective_from: 1.year.ago.to_date)
      Payroll::EntryCalculator.call(period: period, user: employee, business: business)
      sign_in owner
    end

    def deducted = PayrollEntry.find_by!(payroll_period: period, user: employee).obligations_deducted

    it "re-derives the installment count and rebuilds the open payroll entry" do
      patch admin_employee_obligation_path(obligation), params: { employee_obligation: { installment_amount: 250 } }

      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      expect(obligation.reload).to have_attributes(installment_amount: 250, installments_count: 6, remaining_amount: 1_250)
      expect(deducted).to eq(250)
    end

    it "re-renders with 422 and leaves the obligation and payroll unchanged on an invalid edit" do
      patch admin_employee_obligation_path(obligation), params: { employee_obligation: { installment_amount: 5_000 } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(obligation.reload).to have_attributes(installment_amount: 500, remaining_amount: 1_000)
      expect(deducted).to eq(500)
    end
  end

  describe "show" do
    let!(:obligation) do
      create(:employee_obligation, user: employee, business: business, created_by: owner,
                                   start_month: 10, start_year: 2026, total_amount: 1_000, remaining_amount: 1_000,
                                   installment_amount: 300, installments_count: 4)
    end

    before { sign_in owner }

    it "shows the payment schedule with the smaller final installment and the postponement actions" do
      get admin_employee_obligation_path(obligation)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("admin.employee_obligations.payment_schedule"))
      expect(response.body).to include(I18n.t("admin.employee_obligations.final_installment"))
      expect(response.body).to include(I18n.t("admin.employee_obligations.postponement.actions"))
      expect(response.body).not_to include(I18n.t("admin.employee_obligations.locked_for_edit"))
    end

    it "warns that the schedule is locked once a deduction's period is finalized, and hides edit" do
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 10, status: "finalized")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
                                    deducted_amount: 300, remaining_before: 1_000, remaining_after: 700)

      get admin_employee_obligation_path(obligation)

      expect(response.body).to include(I18n.t("admin.employee_obligations.locked_for_edit"))
      expect(response.body).not_to include(edit_admin_employee_obligation_path(obligation))
      expect(response.body).to include(cancel_admin_employee_obligation_path(obligation))
    end
  end

  describe "area and self scopes" do
    let(:branch_a) { create(:branch, business: business) }
    let(:branch_b) { create(:branch, business: business) }
    let(:shift)    { create(:shift, :fixed_time, business: business) }

    def employee_at(branch)
      create(:user, business: business).tap { |u| create(:shift_assignment, user: u, branch: branch, shift: shift) }
    end

    def obligation_for(user, title)
      create(:employee_obligation, user: user, business: business, created_by: owner, title: title)
    end

    def listed_titles
      Nokogiri::HTML(response.body).css(".obl-title").map { |node| node.text.strip }
    end

    it "area scope reaches the branches the actor area-manages only" do
      area_manager = api_user_with(business, :view_employees, :manage_obligations, scopes: { "manage_obligations" => "area" })
      branch_a.update_column(:area_manager_id, area_manager.id)
      obligation_for(employee_at(branch_a), "In area")
      obligation_for(employee_at(branch_b), "Outside area")
      sign_in area_manager

      get admin_employee_obligations_path

      expect(listed_titles).to eq([ "In area" ])
    end

    it "self scope shows only the actor's own obligations, read-only" do
      self_scoped = api_user_with(business, :view_employees, :manage_obligations, scopes: { "manage_obligations" => "self" })
      own = obligation_for(self_scoped, "Own loan")
      obligation_for(employee_at(branch_a), "Colleague loan")
      sign_in self_scoped

      get admin_employee_obligations_path
      expect(listed_titles).to eq([ "Own loan" ])

      get admin_employee_obligation_path(own)
      expect(response.body).not_to include(cancel_admin_employee_obligation_path(own))
    end
  end
end
