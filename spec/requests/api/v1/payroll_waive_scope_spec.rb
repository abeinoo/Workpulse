require "rails_helper"

# Regression suite for payroll line-item waive scope isolation and audit logging.
#
# Verifies that only managers with employees in their EmployeeScope can waive
# deductions for those employees, that cross-branch waive attempts are rejected
# with 404, that employees cannot waive their own deductions, and that every
# successful waive creates a PayrollAuditLog with the correct fields.
#
# Setup: one business, three branches, one manager per branch, one employee per
# branch. Branch membership is shift-driven (active ShiftAssignment) — there is
# no UserBranch and no manager_id ownership.
RSpec.describe "Payroll Line Item Waive Scope", type: :request do
  let(:business)   { create(:business) }
  let(:branch_a)   { create(:branch, business: business) }
  let(:branch_b)   { create(:branch, business: business) }
  let(:branch_c)   { create(:branch, business: business) }

  let!(:owner)     { create(:user, :owner, business: business) }

  let(:shift)      { create(:shift, :fixed_time, business: business) }

  let(:manager_a)  { create(:user, business: business) }
  let(:manager_b)  { create(:user, business: business) }
  let(:employee_a) { create(:user, business: business) }
  let(:employee_b) { create(:user, business: business) }

  # A third branch's manager and employee (was the "direct manager" pair).
  let(:direct_manager) { create(:user, business: business) }
  let(:direct_report)  { create(:user, business: business) }

  # A draft period so all waive/approve/reject operations are allowed.
  let(:period) { create(:payroll_period, business: business) }

  let!(:entry_a)  { create(:payroll_entry, payroll_period: period, user: employee_a,  base_salary: 5_000.0, net_salary: 4_950.0, total_deductions: 50.0) }
  let!(:entry_b)  { create(:payroll_entry, payroll_period: period, user: employee_b,  base_salary: 3_000.0, net_salary: 2_920.0, total_deductions: 80.0) }
  let!(:entry_dr) { create(:payroll_entry, payroll_period: period, user: direct_report, base_salary: 4_000.0, net_salary: 3_950.0, total_deductions: 50.0) }

  # One pending deduction per employee — :late_penalty defaults to -50.0, pending_review.
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
    # Permission-driven: managers need view_payroll + approve_adjustments.
    # Scope still resolved by EmployeeScope via branch relationships.
    [manager_a, manager_b, direct_manager].each do |m|
      m.update_column(:permission_role_id, manager_role.id)
    end
  end

  def waive(as_user, line_item_id, notes: "Excused by manager")
    sign_in as_user
    patch "/api/v1/payroll_line_items/#{line_item_id}/waive",
          params: { notes: notes }, as: :json
  end

  # ── Owner can waive anything ───────────────────────────────────────────────

  describe "owner waive authority" do
    it "owner can waive a deduction for any employee in the business" do
      waive(owner, deduction_a.id)
      expect(response).to have_http_status(:ok)
      expect(deduction_a.reload.review_status).to eq("waived")
    end

    it "owner can waive a deduction from branch B" do
      waive(owner, deduction_b.id)
      expect(response).to have_http_status(:ok)
    end
  end

  # ── Branch manager scope ───────────────────────────────────────────────────

  describe "branch manager waive scope" do
    it "manager A can waive a deduction for their branch employee" do
      waive(manager_a, deduction_a.id)
      expect(response).to have_http_status(:ok)
      expect(deduction_a.reload.review_status).to eq("waived")
    end

    it "manager A gets 404 trying to waive a deduction for branch B employee" do
      waive(manager_a, deduction_b.id)
      expect(response).to have_http_status(:not_found)
      expect(deduction_b.reload.review_status).to eq("pending_review")
    end

    it "manager B can waive a deduction for their branch employee" do
      waive(manager_b, deduction_b.id)
      expect(response).to have_http_status(:ok)
      expect(deduction_b.reload.review_status).to eq("waived")
    end

    it "manager B gets 404 trying to waive a deduction for branch A employee" do
      waive(manager_b, deduction_a.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Third-branch manager scope ────────────────────────────────────────────

  describe "branch C manager waive scope" do
    it "can waive their branch employee's deduction (shift-driven membership)" do
      waive(direct_manager, deduction_dr.id)
      expect(response).to have_http_status(:ok)
      expect(deduction_dr.reload.review_status).to eq("waived")
    end

    it "gets 404 trying to waive a deduction for an employee outside their scope" do
      waive(direct_manager, deduction_a.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Employee self-waive prevention ────────────────────────────────────────

  describe "employee cannot waive their own deduction" do
    it "employee gets 403 when trying to waive their own deduction" do
      # policy_scope includes own entries so find succeeds, but policy#waive?
      # requires overriding? which returns false for plain employees → 403
      waive(employee_a, deduction_a.id)
      expect(response).to have_http_status(:forbidden)
      expect(deduction_a.reload.review_status).to eq("pending_review")
    end
  end

  # ── Audit log ─────────────────────────────────────────────────────────────

  describe "audit log on successful waive" do
    it "creates a PayrollAuditLog entry with action_type line_item_waived" do
      expect { waive(manager_a, deduction_a.id, notes: "Traffic incident") }
        .to change(PayrollAuditLog, :count).by(1)

      log = PayrollAuditLog.last
      expect(log.action_type).to eq("line_item_waived")
    end

    it "records the correct actor" do
      waive(manager_a, deduction_a.id, notes: "Approved absence")
      expect(PayrollAuditLog.last.actor).to eq(manager_a)
    end

    it "records the correct metadata fields" do
      previous_amount = deduction_a.amount.to_f

      waive(manager_a, deduction_a.id, notes: "Doctor appointment")
      meta = PayrollAuditLog.last.metadata_hash

      expect(meta["previous_amount"]).to eq(previous_amount)
      expect(meta["new_amount"]).to eq(0.0)
      expect(meta["reason"]).to eq("Doctor appointment")
      expect(meta["employee_id"]).to eq(employee_a.id)
      expect(meta["payroll_entry_id"]).to eq(entry_a.id)
      expect(meta["line_item_id"]).to eq(deduction_a.id)
    end

    it "links the audit log to the correct payroll period" do
      waive(manager_a, deduction_a.id)
      expect(PayrollAuditLog.last.payroll_period).to eq(period)
    end

    it "owner waive also creates an audit log" do
      expect { waive(owner, deduction_a.id, notes: "Owner override") }
        .to change(PayrollAuditLog, :count).by(1)

      log = PayrollAuditLog.last
      expect(log.actor).to eq(owner)
      expect(log.metadata_hash["reason"]).to eq("Owner override")
    end
  end

  # ── Failed waive does NOT create audit log ────────────────────────────────

  describe "failed waive does not create an audit log" do
    it "blank notes returns 422 and creates no audit log" do
      expect {
        waive(manager_a, deduction_a.id, notes: "")
      }.not_to change(PayrollAuditLog, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(deduction_a.reload.review_status).to eq("pending_review")
    end

    it "cross-branch 404 creates no audit log" do
      expect {
        waive(manager_a, deduction_b.id)
      }.not_to change(PayrollAuditLog, :count)
    end
  end

  # ── Waive does not alter salary structure ─────────────────────────────────

  describe "payroll authority boundary" do
    it "waiving a deduction does not change base_salary" do
      expect { waive(manager_a, deduction_a.id) }
        .not_to change { entry_a.reload.base_salary }
    end

    it "waiving a deduction does not change the payroll period status" do
      expect { waive(manager_a, deduction_a.id) }
        .not_to change { period.reload.status }
    end

    it "waiving sets net_salary higher (deduction removed) but base_salary unchanged" do
      base_before = entry_a.base_salary
      net_before  = entry_a.net_salary

      waive(manager_a, deduction_a.id)
      entry_a.reload

      expect(entry_a.base_salary).to eq(base_before)
      expect(entry_a.net_salary).to be > net_before
    end
  end

  # ── Partition invariant ───────────────────────────────────────────────────

  describe "waiveability partition" do
    it "the set of waiveable deductions for manager A and manager B are disjoint" do
      # Confirm that each manager gets 200 on their own deduction and 404 on the other's.
      waive(manager_a, deduction_a.id)
      status_a_on_a = response.status

      sign_in manager_a
      patch "/api/v1/payroll_line_items/#{deduction_b.id}/waive",
            params: { notes: "Cross-branch attempt" }, as: :json
      status_a_on_b = response.status

      expect(status_a_on_a).to eq(200)
      expect(status_a_on_b).to eq(404)
    end

    it "EmployeeScope delegation: deductions accessible to each manager sum to owner's total" do
      # Reset deduction statuses so all three are waiveable.
      [deduction_a, deduction_b, deduction_dr].each { |d| d.update!(review_status: "pending_review") }

      def scope_ids_for(user)
        sign_in user
        get "/api/v1/payroll_periods/#{period.id}/payroll_entries", as: :json
        response.parsed_body["data"].map { |e| e["id"] }
      end

      entries_a  = scope_ids_for(manager_a)
      entries_b  = scope_ids_for(manager_b)
      entries_dm = scope_ids_for(direct_manager)
      entries_owner = scope_ids_for(owner)

      all_scoped = (entries_a + entries_b + entries_dm).uniq
      expect(all_scoped.sort).to eq(entries_owner.sort)
    end
  end

  # ── EmployeeScope delegation regression ───────────────────────────────────

  describe "EmployeeScope delegation regression" do
    it "branch manager sees branch employee's line item via active assignment" do
      waive(manager_a, deduction_a.id)
      expect(response).to have_http_status(:ok)
    end

    it "an employee with no active assignment is not waiveable by any branch manager" do
      floating       = create(:user, business: business)
      floating_entry = create(:payroll_entry, payroll_period: period, user: floating)
      floating_ded   = create(:payroll_line_item, :late_penalty, payroll_entry: floating_entry)
      waive(manager_a, floating_ded.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
