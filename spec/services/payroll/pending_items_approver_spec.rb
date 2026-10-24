require "rails_helper"

RSpec.describe Payroll::PendingItemsApprover do
  let(:business) { create(:business) }
  let(:creator)  { create(:user, :accountant, business: business) }
  let(:approver) { create(:user, :accountant, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:period)   { create(:payroll_period, business: business, status: "under_review") }
  let!(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, net_salary: 5_000.0, total_bonuses: 0.0, total_deductions: 0.0)
  end

  # A review-time adjustment plus the pending line item it materialises as.
  def pending_adjustment_item(created_by:, amount: 300.0)
    adj = create(:payroll_adjustment, :cash_incentive, payroll_period: period, business: business,
                 user: employee, created_by: created_by, amount: amount)
    li  = create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive", amount: amount,
                 source_type: "PayrollAdjustment", source_id: adj.id, review_status: "pending_review")
    [ adj, li ]
  end

  def system_item
    create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -50.0,
           review_status: "pending_review")
  end

  def state
    { items: PayrollLineItem.where(payroll_entry: entry).order(:id).pluck(:review_status),
      adjustments: PayrollAdjustment.where(payroll_period: period).order(:id).pluck(:review_status),
      net: entry.reload.net_salary, logs: PayrollAuditLog.where(payroll_period: period).count }
  end

  def call(reviewer = approver) = described_class.call(period_id: period.id, reviewer: reviewer)

  it "approves system items and other people's adjustments, syncing the source adjustment" do
    adj, li = pending_adjustment_item(created_by: creator)
    late    = system_item

    result = call

    expect(result).to be_ok
    expect([ result.approved, result.skipped ]).to eq([ 2, 0 ])
    expect(li.reload).to be_approved
    expect(late.reload).to be_approved
    expect(adj.reload).to have_attributes(review_status: "approved", approved_by_id: approver.id)
    expect(entry.reload.net_salary).to eq(5_250.0) # +300 incentive −50 late
    log = PayrollAuditLog.find_by(payroll_period: period, action_type: "adjustment_approved")
    expect(JSON.parse(log.metadata)).to include("bulk_approved" => true, "count" => 2, "skipped" => 0)
  end

  it "skips the reviewer's own adjustment — line item AND source stay pending" do
    own_adj, own_li     = pending_adjustment_item(created_by: approver)
    other_adj, other_li = pending_adjustment_item(created_by: creator, amount: 100.0)

    result = call

    expect([ result.approved, result.skipped ]).to eq([ 1, 1 ])
    expect(own_li.reload).to be_pending_review
    expect(own_adj.reload).to be_pending_review
    expect(other_li.reload).to be_approved
    expect(other_adj.reload).to be_approved
    expect(entry.reload.net_salary).to eq(5_100.0)
  end

  it "skips adjustment items for a reviewer without approve_adjustments (system items still approved)" do
    role     = create(:permission_role, business: business, permissions: %w[view_payroll approve_payroll_items])
    reviewer = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }.reload
    adj, li  = pending_adjustment_item(created_by: creator)
    late     = system_item

    result = call(reviewer)

    expect([ result.approved, result.skipped ]).to eq([ 1, 1 ])
    expect(li.reload).to be_pending_review
    expect(adj.reload).to be_pending_review
    expect(late.reload).to be_approved
  end

  %w[finalized paid].each do |status|
    it "refuses a #{status} period and changes nothing" do
      pending_adjustment_item(created_by: creator)
      system_item
      period.update_column(:status, status)
      before = state

      result = call

      expect(result).not_to be_ok
      expect(result.error).to eq(:not_reviewable)
      expect(state).to eq(before)
    end
  end

  it "reports no_pending_items when nothing is pending" do
    expect(call.error).to eq(:no_pending_items)
    expect(PayrollAuditLog.where(payroll_period: period)).to be_empty
  end

  it "refuses the whole run (no partial writes) when a pending item's source adjustment is no longer pending" do
    adj, = pending_adjustment_item(created_by: creator)
    system_item
    adj.update_column(:review_status, "rejected") # diverged: item pending, source rejected
    before = state

    expect { call }.to raise_error(PayrollAdjustment::ReviewTransitionError)
    expect(state).to eq(before)
  end

  it "rolls everything back (items, source adjustments, audit log) when total recalculation fails" do
    pending_adjustment_item(created_by: creator)
    system_item
    before = state
    allow_any_instance_of(PayrollEntry).to receive(:recalculate_totals!)
      .and_raise(ActiveRecord::RecordInvalid.new(PayrollEntry.new))

    expect { call }.to raise_error(ActiveRecord::RecordInvalid)
    expect(state).to eq(before)
  end

  it "refuses another business's period" do
    foreign = create(:payroll_period, business: create(:business))
    expect { described_class.call(period_id: foreign.id, reviewer: approver) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end
