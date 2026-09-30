require "rails_helper"

# Characterization: payroll + reporting endpoints.
RSpec.describe "API v1 characterization — payroll & reports", type: :request do
  let(:business)   { create(:business) }
  let(:branch)     { create(:branch, business: business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:employee)   { create(:user, business: business) }
  let(:shift)      { create(:shift, :fixed_time, business: business) }

  let(:other_business) { create(:business) }

  before { create(:shift_assignment, user: employee, branch: branch, shift: shift) }

  describe "payroll periods" do
    let!(:period) { create(:payroll_period, :under_review, business: business) }
    let!(:entry)  { create(:payroll_entry, payroll_period: period, user: employee) }
    let(:period_keys) do
      %w[id status period_year period_month working_days generated_at finalized_at
         period_label generated_by_id finalized_by_id]
    end

    it "GET /payroll_periods returns an unpaginated array; entry_count only for analytics holders" do
      sign_in accountant
      get "/api/v1/payroll_periods", as: :json
      expect_legacy_success
      expect(api_data.first.keys).to match_array(period_keys + [ "entry_count" ])
    end

    it "GET /payroll_periods omits entry_count without view_payroll_analytics" do
      viewer = api_user_with(business, :view_payroll, :view_draft_payroll)
      sign_in viewer
      get "/api/v1/payroll_periods", as: :json
      expect_legacy_success
      expect(api_data.first.keys).to match_array(period_keys)
    end

    it "GET /payroll_periods/:id adds entries and branch_reviews" do
      sign_in accountant
      get "/api/v1/payroll_periods/#{period.id}", as: :json
      expect_legacy_success
      expect(api_data.keys).to match_array(period_keys + %w[entries branch_reviews])
      expect(api_data["entries"].first.keys).to match_array(%w[
        id user_id salary_type base_salary working_days days_worked total_deductions
        total_overtime total_bonuses already_paid_total advances_deducted
        obligations_deducted net_salary status
      ])
    end

    it "GET /payroll_periods/:id returns 404 for another business's period" do
      foreign = create(:payroll_period, :under_review, business: other_business)
      sign_in owner
      get "/api/v1/payroll_periods/#{foreign.id}", as: :json
      expect_legacy_error(:not_found)
    end

    it "an employee cannot see an under_review period (404)" do
      sign_in employee
      get "/api/v1/payroll_periods/#{period.id}", as: :json
      expect_legacy_error(:not_found)
    end

    it "PATCH /payroll_periods/:id/finalize returns 403 without finalize_payroll" do
      viewer = api_user_with(business, :view_payroll, :view_draft_payroll)
      sign_in viewer
      patch "/api/v1/payroll_periods/#{period.id}/finalize", as: :json
      expect_legacy_error(:forbidden)
    end
  end

  describe "payroll entries" do
    let!(:period) { create(:payroll_period, :paid, business: business) }
    let!(:entry)  { create(:payroll_entry, payroll_period: period, user: employee) }
    let!(:coworker_entry) { create(:payroll_entry, payroll_period: period, user: create(:user, business: business)) }
    let(:entry_keys) do
      %w[id user_id salary_type base_salary working_days days_worked total_deductions total_overtime
         total_bonuses already_paid_total advances_deducted obligations_deducted net_salary status notes
         payroll_period_id gross_salary total_adjustments currency]
    end

    it "GET /payroll_periods/:id/payroll_entries returns only own entries for an employee" do
      sign_in employee
      get "/api/v1/payroll_periods/#{period.id}/payroll_entries", as: :json
      expect_legacy_success
      expect(api_data.map { |e| e["id"] }).to eq([ entry.id ])
      expect(api_data.first.keys).to match_array(entry_keys)
    end

    it "GET /payroll_entries/:id adds line items and an attendance summary" do
      sign_in employee
      get "/api/v1/payroll_periods/#{period.id}/payroll_entries/#{entry.id}", as: :json
      expect_legacy_success
      expect(api_data.keys).to match_array(entry_keys + %w[pending_review_count line_items attendance])
    end

    it "GET a coworker's entry returns 404 for an employee" do
      sign_in employee
      get "/api/v1/payroll_periods/#{period.id}/payroll_entries/#{coworker_entry.id}", as: :json
      expect_legacy_error(:not_found)
    end

    it "PATCH on a paid period's entry returns 422 'Cannot modify a paid payroll entry'" do
      sign_in accountant
      patch "/api/v1/payroll_periods/#{period.id}/payroll_entries/#{entry.id}",
            params: { payroll_entry: { notes: "x" } }, as: :json
      expect_legacy_error(:unprocessable_content, message: "Cannot modify a paid payroll entry")
    end
  end

  describe "payroll line items" do
    let!(:period)    { create(:payroll_period, :under_review, business: business) }
    let!(:entry)     { create(:payroll_entry, payroll_period: period, user: employee) }
    let!(:line_item) { create(:payroll_line_item, :late_penalty, payroll_entry: entry) }

    it "PATCH /payroll_line_items/:id/approve returns 403 for an employee" do
      sign_in employee
      patch "/api/v1/payroll_line_items/#{line_item.id}/approve", as: :json
      expect(response.status).to be_in([ 403, 404 ])
      expect(api_json["success"]).to be(false)
    end

    it "PATCH /payroll_line_items/:id/approve returns 404 for another business's line item" do
      foreign_period = create(:payroll_period, :under_review, business: other_business)
      foreign_entry  = create(:payroll_entry, payroll_period: foreign_period, user: create(:user, business: other_business))
      foreign_item   = create(:payroll_line_item, :late_penalty, payroll_entry: foreign_entry)
      sign_in owner
      patch "/api/v1/payroll_line_items/#{foreign_item.id}/approve", as: :json
      expect_legacy_error(:not_found)
    end

    # KNOWN DEFECT (docs/api/baseline.md → D1): PayrollLineItemPolicy#waive? was
    # renamed to #waive_deduction? (commit d950781) but this controller still
    # calls :waive?, so every request raises NoMethodError (HTTP 500).
    it "PATCH /payroll_line_items/:id/waive answers with an HTTP status instead of raising" do
      pending "D1: Api::V1::PayrollLineItemsController#waive calls the removed policy method waive?"
      sign_in employee
      patch "/api/v1/payroll_line_items/#{line_item.id}/waive", params: { notes: "x" }, as: :json
      expect(response.status).to be_in([ 403, 404 ])
    end
  end

  describe "reports" do
    let!(:period) { create(:payroll_period, :paid, business: business) }
    let!(:entry)  { create(:payroll_entry, payroll_period: period, user: employee) }

    it "GET /reports/payroll/summary returns 401 (not 403) without view_payroll_analytics" do
      sign_in employee
      get "/api/v1/reports/payroll/summary", params: { payroll_period_id: period.id }, as: :json
      expect_legacy_error(:unauthorized, message: "Not authorized")
    end

    it "GET /reports/payroll/summary returns the summary to an analytics holder" do
      sign_in accountant
      get "/api/v1/reports/payroll/summary", params: { payroll_period_id: period.id }, as: :json
      expect_legacy_success
      expect(api_data).to include("totals")
    end

    it "GET /reports/payroll/export returns CSV, not JSON" do
      sign_in accountant
      get "/api/v1/reports/payroll/export", params: { payroll_period_id: period.id }
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
    end

    it "GET /reports/attendance returns 401 (not 403) without view/manage_employees" do
      sign_in employee
      get "/api/v1/reports/attendance", params: { start_date: "2026-09-01", end_date: "2026-09-30" }, as: :json
      expect_legacy_error(:unauthorized, message: "Not authorized")
    end

    it "GET /reports/attendance returns 422 on an invalid date" do
      sign_in owner
      get "/api/v1/reports/attendance", params: { start_date: "bad", end_date: "2026-09-30" }, as: :json
      expect_legacy_error(:unprocessable_content)
      expect(api_json["message"]).to start_with("Invalid date parameter")
    end

    it "GET /reports/attendance returns 404 for another business's branch" do
      sign_in owner
      get "/api/v1/reports/attendance",
          params: { start_date: "2026-09-01", end_date: "2026-09-30", branch_id: create(:branch, business: other_business).id },
          as: :json
      expect_legacy_error(:not_found)
    end

    # KNOWN DEFECT (docs/api/baseline.md → S2): without branch_id the summary
    # is business-wide for anyone holding view_employees, ignoring their scope.
    it "GET /reports/attendance limits a branch manager to their own branches" do
      pending "S2: Reports::AttendanceController ignores the caller's employee/branch scope when branch_id is omitted"
      other_branch   = create(:branch, business: business)
      outsider       = create(:user, business: business)
      # The attendance_record factory also creates the outsider's assignment to other_branch.
      create(:attendance_record, :checked_out, business: business, user: outsider, branch: other_branch,
             date: Date.new(2026, 9, 10), work_date: Date.new(2026, 9, 10))
      manager = api_user_with(business, :view_employees)
      branch.update_column(:branch_manager_id, manager.id)

      sign_in manager
      get "/api/v1/reports/attendance", params: { start_date: "2026-09-01", end_date: "2026-09-30" }, as: :json
      expect(api_data["employees"].map { |e| e["user_id"] }).not_to include(outsider.id)
    end
  end
end
