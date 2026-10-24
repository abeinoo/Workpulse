require "rails_helper"

# The API's "approve all pending" goes through the same Payroll::PendingItemsApprover
# as the web action — it must not be a weaker approval path (it used to approve
# every pending item, including the caller's own adjustments, and left the source
# PayrollAdjustment pending).
RSpec.describe "API::V1 PayrollPeriods approve_all_pending", type: :request do
  let(:business) { create(:business) }
  let(:creator)  { create(:user, :accountant, business: business) }
  let(:approver) { create(:user, :accountant, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:period)   { create(:payroll_period, business: business, status: "under_review") }
  let!(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, net_salary: 5_000.0, total_bonuses: 0.0, total_deductions: 0.0)
  end

  def pending_adjustment_item(created_by:, amount: 300.0)
    adj = create(:payroll_adjustment, :cash_incentive, payroll_period: period, business: business,
                 user: employee, created_by: created_by, amount: amount)
    li  = create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive", amount: amount,
                 source_type: "PayrollAdjustment", source_id: adj.id, review_status: "pending_review")
    [ adj, li ]
  end

  def json = JSON.parse(response.body)

  it "approves another user's adjustment and moves the source adjustment to approved" do
    adj, li = pending_adjustment_item(created_by: creator)

    sign_in approver
    patch approve_all_pending_api_v1_payroll_period_path(period)

    expect(response).to have_http_status(:ok)
    expect(json.dig("data", "approved_count")).to eq(1)
    expect(json.dig("data", "skipped_count")).to eq(0)
    expect(li.reload).to be_approved
    expect(adj.reload).to have_attributes(review_status: "approved", approved_by_id: approver.id)
    expect(entry.reload.net_salary).to eq(5_300.0)
    expect(PayrollAuditLog.where(payroll_period: period, action_type: "adjustment_approved").count).to eq(1)
  end

  it "skips the caller's own adjustment (no self-approval through the API)" do
    own_adj, own_li = pending_adjustment_item(created_by: approver)

    sign_in approver
    patch approve_all_pending_api_v1_payroll_period_path(period)

    expect(response).to have_http_status(:ok)
    expect(json.dig("data", "approved_count")).to eq(0)
    expect(json.dig("data", "skipped_count")).to eq(1)
    expect(own_li.reload).to be_pending_review
    expect(own_adj.reload).to be_pending_review
    expect(entry.reload.net_salary).to eq(5_000.0)
  end

  it "refuses (403) a pipeline user who can see the period but lacks approve_payroll_items" do
    adj, li = pending_adjustment_item(created_by: creator)

    sign_in api_user_with(business, :view_payroll, :submit_payroll_review, :view_adjustments, :approve_adjustments)
    patch approve_all_pending_api_v1_payroll_period_path(period)

    expect(response).to have_http_status(:forbidden)
    expect(li.reload).to be_pending_review
    expect(adj.reload).to be_pending_review
  end

  it "refuses (404) a user who cannot even see the under-review period" do
    adj, li = pending_adjustment_item(created_by: creator)

    sign_in api_user_with(business, :view_payroll, :view_adjustments, :approve_adjustments)
    patch approve_all_pending_api_v1_payroll_period_path(period)

    expect(response).to have_http_status(:not_found)
    expect(li.reload).to be_pending_review
    expect(adj.reload).to be_pending_review
  end

  %w[finalized paid].each do |status|
    it "refuses a #{status} period and changes nothing" do
      adj, li = pending_adjustment_item(created_by: creator)
      period.update_column(:status, status)

      sign_in approver
      patch approve_all_pending_api_v1_payroll_period_path(period)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["message"]).to eq("Period is not reviewable")
      expect(li.reload).to be_pending_review
      expect(adj.reload).to be_pending_review
      expect(entry.reload.net_salary).to eq(5_000.0)
    end
  end

  it "refuses (422) without partial writes when a source adjustment has diverged" do
    adj, li = pending_adjustment_item(created_by: creator)
    adj.update_column(:review_status, "rejected")

    sign_in approver
    patch approve_all_pending_api_v1_payroll_period_path(period)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(json["message"]).to eq(I18n.t("adjustments.errors.not_pending"))
    expect(li.reload).to be_pending_review
    expect(adj.reload).to be_rejected
  end
end
