require "rails_helper"

# Proves the SINGLE approval rule holds across every payroll-review approval path:
#   B  — review-time adjustment creation (PayrollAdjustmentsController#create)
#   D1 — single line-item review (PayrollLineItemsController#approve)
#   D2 — bulk "approve all pending" (PayrollPeriodsController#approve_all_pending)
#
# Invariants under test:
#   * a creator (Branch Manager OR Accountant) can never approve their own adjustment
#   * creator and approver are always different users
#   * unapproved adjustments never affect net_salary
RSpec.describe "Payroll review approval paths", type: :request do
  let(:business) { create(:business) }

  # Two independent approvers (both hold manage + approve_adjustments).
  let(:accountant_creator)  { create(:user, :accountant, business: business) }
  let(:accountant_approver) { create(:user, :accountant, business: business) }

  # Branch manager + an employee inside the branch they manage.
  let(:branch_manager) { create(:user, :branch_manager, business: business) }
  let(:bm_branch)      { Branch.find_by(business: business, branch_manager_id: branch_manager.id) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:employee) do
    u = create(:user, business: business)
    create(:shift_assignment, user: u, branch: bm_branch, shift: shift)
    u
  end

  let(:period) { create(:payroll_period, business: business, status: "under_review", period_month: 7, period_year: 2026) }
  let!(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, net_salary: 5_000.0, total_bonuses: 0.0, total_deductions: 0.0)
  end

  def create_review_adjustment(as:, amount: 500.0, type: "cash_incentive")
    sign_in as
    post payroll_period_payroll_entry_payroll_adjustments_path(period, entry),
         params: { payroll_adjustment: { adjustment_type: type, amount: amount, reason: "Perf" } }
    sign_out as
    PayrollLineItem.where(source_type: "PayrollAdjustment").order(:id).last
  end

  # ── Path B: review-time creation defaults to Pending and does not pay out ──
  describe "Path B — review-time creation" do
    it "creates a PENDING adjustment + PENDING line item and leaves net_salary untouched" do
      li = create_review_adjustment(as: branch_manager)

      expect(li.review_status).to eq("pending_review")
      expect(li.source_adjustment.review_status).to eq("pending_review")
      expect(li.source_adjustment.approved_by).to be_nil
      expect(entry.reload.net_salary).to eq(5_000.0)   # unapproved → no effect
      expect(entry.total_bonuses).to eq(0.0)
    end
  end

  # ── Path D1: single line-item review ──────────────────────────────────────
  describe "Path D1 — single line-item review" do
    it "blocks the Branch Manager from approving the item they created" do
      li = create_review_adjustment(as: branch_manager)

      sign_in branch_manager
      patch approve_payroll_period_payroll_entry_payroll_line_item_path(period, entry, li)
      sign_out branch_manager

      expect(li.reload.review_status).to eq("pending_review")
      expect(entry.reload.net_salary).to eq(5_000.0)
    end

    it "blocks the Accountant from approving the item they created" do
      li = create_review_adjustment(as: accountant_creator)

      sign_in accountant_creator
      patch approve_payroll_period_payroll_entry_payroll_line_item_path(period, entry, li)
      sign_out accountant_creator

      expect(li.reload.review_status).to eq("pending_review")
    end

    it "lets a different approver approve, pays out, and records a distinct approver" do
      li = create_review_adjustment(as: branch_manager, amount: 500.0)

      sign_in accountant_approver
      patch approve_payroll_period_payroll_entry_payroll_line_item_path(period, entry, li)
      sign_out accountant_approver

      li.reload
      expect(li.review_status).to eq("approved")
      adj = li.source_adjustment
      expect(adj.review_status).to eq("approved")
      expect(adj.approved_by).to eq(accountant_approver)
      expect(adj.approved_by).not_to eq(adj.created_by)        # creator != approver
      expect(entry.reload.net_salary).to eq(5_500.0)           # now paid out
    end
  end

  # ── Path D2: bulk approve-all-pending (requires approve_payroll_items) ─────
  describe "Path D2 — approve all pending" do
    it "skips items the approver created and approves only others" do
      own_li   = create_review_adjustment(as: accountant_creator, amount: 100.0)   # created by approver-to-be
      other_li = create_review_adjustment(as: branch_manager,     amount: 300.0)   # created by someone else

      sign_in accountant_creator
      patch approve_all_pending_payroll_period_path(period)
      sign_out accountant_creator

      expect(own_li.reload.review_status).to eq("pending_review")  # self-created → skipped
      expect(other_li.reload.review_status).to eq("approved")      # other-created → approved
      expect(other_li.source_adjustment.approved_by).to eq(accountant_creator)
      expect(other_li.source_adjustment.approved_by).not_to eq(other_li.source_adjustment.created_by)
    end
  end
end
