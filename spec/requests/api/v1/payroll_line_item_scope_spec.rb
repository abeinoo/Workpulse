require "rails_helper"

# Scope isolation for the /api/v1 payroll line-item actions, plus the retirement
# of PATCH /api/v1/payroll_line_items/:id/waive.
#
# The waive endpoint was retired (docs/api/baseline.md → D1): waiving a deduction
# is Payroll::DeductionWaiver's job behind PayrollLineItemPolicy#waive_deduction?
# (web only), and the API action still called the removed waive? policy method.
# The scope guarantees its old spec (payroll_waive_scope_spec) pinned still hold
# for the remaining actions, which share the same policy_scope lookup.
#
# Setup: one business, three branches, one manager per branch, one employee per
# branch. Branch membership is shift-driven (active ShiftAssignment) — there is
# no UserBranch and no manager_id ownership.
RSpec.describe "Payroll line item API scope", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:branch_c) { create(:branch, business: business) }

  let!(:owner) { create(:user, :owner, business: business) }

  let(:shift) { create(:shift, :fixed_time, business: business) }

  let(:manager_a)      { create(:user, business: business) }
  let(:manager_b)      { create(:user, business: business) }
  let(:direct_manager) { create(:user, business: business) }
  let(:employee_a)     { create(:user, business: business) }
  let(:employee_b)     { create(:user, business: business) }
  let(:direct_report)  { create(:user, business: business) }

  # A draft period, so line-item review is allowed.
  let(:period) { create(:payroll_period, business: business) }

  let!(:entry_a)  { create(:payroll_entry, payroll_period: period, user: employee_a) }
  let!(:entry_b)  { create(:payroll_entry, payroll_period: period, user: employee_b) }
  let!(:entry_dr) { create(:payroll_entry, payroll_period: period, user: direct_report) }

  # One pending deduction per employee (:late_penalty is pending_review).
  let!(:deduction_a)  { create(:payroll_line_item, :late_penalty, payroll_entry: entry_a) }
  let!(:deduction_b)  { create(:payroll_line_item, :early_leave_penalty, payroll_entry: entry_b) }
  let!(:deduction_dr) { create(:payroll_line_item, :late_penalty, payroll_entry: entry_dr) }

  let(:manager_role) do
    create(:permission_role, business: business,
           permissions: %w[view_payroll view_employees view_adjustments approve_adjustments],
           permission_scopes: {})
  end

  before do
    branch_a.update_column(:branch_manager_id, manager_a.id)
    branch_b.update_column(:branch_manager_id, manager_b.id)
    branch_c.update_column(:branch_manager_id, direct_manager.id)
    create(:shift_assignment, user: employee_a,    branch: branch_a, shift: shift)
    create(:shift_assignment, user: employee_b,    branch: branch_b, shift: shift)
    create(:shift_assignment, user: direct_report, branch: branch_c, shift: shift)
    [ manager_a, manager_b, direct_manager ].each { |m| m.update_column(:permission_role_id, manager_role.id) }
  end

  def approve(as_user, line_item_id)
    sign_in as_user
    patch "/api/v1/payroll_line_items/#{line_item_id}/approve", as: :json
  end

  describe "retired waive endpoint" do
    it "is no longer routed" do
      expect { Rails.application.routes.recognize_path("/api/v1/payroll_line_items/1/waive", method: :patch) }
        .to raise_error(ActionController::RoutingError)
    end

    it "answers 404 and leaves the deduction untouched" do
      sign_in owner
      patch "/api/v1/payroll_line_items/#{deduction_a.id}/waive", params: { notes: "x" }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(deduction_a.reload.review_status).to eq("pending_review")
    end
  end

  describe "branch managers reach only their own branch's line items" do
    it "manager A reaches their branch employee's deduction" do
      approve(manager_a, deduction_a.id)
      expect(response).to have_http_status(:ok)
      expect(deduction_a.reload.review_status).to eq("approved")
    end

    it "manager A gets 404 for a branch B deduction" do
      approve(manager_a, deduction_b.id)
      expect(response).to have_http_status(:not_found)
      expect(deduction_b.reload.review_status).to eq("pending_review")
    end

    it "manager B gets 404 for a branch A deduction" do
      approve(manager_b, deduction_a.id)
      expect(response).to have_http_status(:not_found)
    end

    it "the branch C manager reaches their branch employee's deduction (shift-driven membership)" do
      approve(direct_manager, deduction_dr.id)
      expect(response).to have_http_status(:ok)
    end

    it "the branch C manager gets 404 for an employee outside their scope" do
      approve(direct_manager, deduction_a.id)
      expect(response).to have_http_status(:not_found)
    end

    it "no branch manager reaches an employee with no active assignment" do
      floating       = create(:user, business: business)
      floating_entry = create(:payroll_entry, payroll_period: period, user: floating)
      floating_ded   = create(:payroll_line_item, :late_penalty, payroll_entry: floating_entry)

      approve(manager_a, floating_ded.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "EmployeeScope delegation: the branch managers' payroll entries together equal the owner's" do
    scope_ids_for = lambda do |user|
      sign_in user
      get "/api/v1/payroll_periods/#{period.id}/payroll_entries", as: :json
      response.parsed_body["data"].map { |e| e["id"] }
    end

    all_scoped = [ manager_a, manager_b, direct_manager ].flat_map { |m| scope_ids_for.call(m) }.uniq
    expect(all_scoped.sort).to eq(scope_ids_for.call(owner).sort)
  end
end
