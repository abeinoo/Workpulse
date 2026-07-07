require "rails_helper"

RSpec.describe "Payroll deduction waivers", type: :request do
  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:employee)   { create(:user, business: business) }
  let(:no_perm)    { create(:user, business: business) }

  let(:period) { create(:payroll_period, business: business, status: :draft) }
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, total_deductions: 100.0, net_salary: 4_900.0)
  end
  let!(:deduction) do
    create(:payroll_line_item, :manual_deduction, payroll_entry: entry, amount: -100.0)
  end

  describe "PATCH waive_deduction" do
    it "waives the deduction for an authorised user" do
      sign_in accountant
      patch waive_deduction_payroll_period_payroll_entry_payroll_line_item_path(period, entry, deduction),
            params: { reason: "Goodwill gesture" }

      expect(response).to redirect_to(payroll_period_payroll_entry_path(period, entry))
      expect(deduction.reload.deduction_waived?).to be true
      expect(entry.reload.net_salary).to eq(5_000.0)
    end

    it "redirects with an alert when no reason is given" do
      sign_in accountant
      patch waive_deduction_payroll_period_payroll_entry_payroll_line_item_path(period, entry, deduction),
            params: { reason: "" }

      expect(flash[:alert]).to eq(I18n.t("payroll.deduction_waiver.errors.reason_required"))
      expect(deduction.reload.deduction_waived?).to be false
    end

    it "forbids a user without the permission" do
      sign_in no_perm
      patch waive_deduction_payroll_period_payroll_entry_payroll_line_item_path(period, entry, deduction),
            params: { reason: "x" }

      # policy_scope hides the line item from a user who cannot see it (404), and
      # the dedicated permission gate would otherwise block it (302). Either way
      # the waiver must not be applied.
      expect(response).not_to have_http_status(:ok)
      expect(deduction.reload.deduction_waived?).to be false
    end

    it "writes an audit log" do
      sign_in accountant
      expect {
        patch waive_deduction_payroll_period_payroll_entry_payroll_line_item_path(period, entry, deduction),
              params: { reason: "Goodwill" }
      }.to change { PayrollAuditLog.where(action_type: "deduction_waived").count }.by(1)
    end
  end

  describe "PATCH restore_deduction" do
    before do
      Payroll::DeductionWaiver.call(line_item: deduction, action: "waive", actor: accountant, reason: "x")
    end

    it "restores the deduction for an authorised user" do
      sign_in accountant
      patch restore_deduction_payroll_period_payroll_entry_payroll_line_item_path(period, entry, deduction)

      expect(deduction.reload.deduction_waived?).to be false
      expect(entry.reload.net_salary).to eq(4_900.0)
    end
  end

  describe "PATCH waive_deductions (bulk)" do
    it "waives manual deductions for the selected employees" do
      sign_in accountant
      patch waive_deductions_payroll_period_path(period),
            params: { entry_ids: [ entry.id ], waiver_action: "waive", reason: "Bulk" }

      expect(response).to redirect_to(payroll_period_path(period))
      expect(deduction.reload.deduction_waived?).to be true
    end

    it "forbids a user without the permission" do
      sign_in no_perm
      patch waive_deductions_payroll_period_path(period),
            params: { entry_ids: [ entry.id ], waiver_action: "waive", reason: "Bulk" }

      expect(deduction.reload.deduction_waived?).to be false
    end
  end

  describe "employee payslip visibility" do
    let(:finalized) { create(:payroll_period, :finalized, business: business, period_year: 2025, period_month: 5) }
    let(:f_entry) do
      create(:payroll_entry, :approved, payroll_period: finalized, user: employee,
             base_salary: 5_000.0, total_deductions: 0.0, net_salary: 5_000.0)
    end
    let!(:waived) do
      create(:payroll_line_item, :manual_deduction, :deduction_waived,
             payroll_entry: f_entry, amount: -100.0)
    end

    it "does not expose waiver details (reason/original amount) to the employee" do
      sign_in employee
      get payroll_period_payroll_entry_path(finalized, f_entry)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Waived during review")
      # The deduction itself (manager-only waiver detail column and note) must
      # stay hidden, even though the deduction row now appears in the merged
      # deductions table so the employee can see it affected their net salary.
      expect(response.body).not_to include(">#{I18n.t('payroll.deduction_waiver.status_label')}<")
      expect(response.body).not_to include(I18n.t("payroll.deduction_waiver.waived_by", name: ""))
    end
  end
end
