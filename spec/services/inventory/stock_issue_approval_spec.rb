require "rails_helper"

RSpec.describe Inventory::StockIssueApproval, type: :model do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let(:requester)  { create(:user, business: business) }
  let(:approver)   { create(:user, business: business) }
  let(:warehouse)  { business.warehouses.create!(name: "Main") }
  let(:branch)     { business.branches.create!(name: "Nasr City", active: true) }
  let(:product)    { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }

  # Approval reserves stock, so it needs some on hand to reserve.
  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def pending_issue(submitted_by: requester)
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: submitted_by)
    i.items.build(product: product, quantity: 1)
    i.status = :pending_approval
    i.submitted_by = submitted_by
    i.submitted_at = Time.current
    i.save!
    i
  end

  def approval_for(issue, actor:)
    described_class.new(stock_issue_id: issue.id, actor: actor)
  end

  describe "#approve!" do
    it "moves pending_approval to approved, records who/when, and logs it — without posting stock" do
      issue = pending_issue

      result = approval_for(issue, actor: approver).approve!

      expect(result.ok?).to be(true)
      issue.reload
      expect(issue).to be_approved
      expect(issue.approved_by).to eq(approver)
      expect(issue.approved_at).to be_present
      expect(issue.inventory_movements.count).to eq(0)

      log = AuditLog.for_auditable(issue).find_by(action: "approve")
      expect(log.actor).to eq(approver)
    end

    it "blocks self-approval by the submitter, with the owner exception" do
      issue = pending_issue(submitted_by: requester)

      self_result = approval_for(issue, actor: requester).approve!
      expect(self_result.ok?).to be(false)
      expect(self_result.error).to eq(Approvals::SelfApproval.error_message)
      expect(issue.reload).to be_pending_approval

      owner_issue = pending_issue(submitted_by: owner)
      owner_result = approval_for(owner_issue, actor: owner).approve!
      expect(owner_result.ok?).to be(true)
    end

    it "refuses to approve a draft (never submitted) issue" do
      issue = pending_issue
      issue.update_column(:status, "draft")

      result = approval_for(issue, actor: approver).approve!
      expect(result.ok?).to be(false)
    end

    it "refuses to approve an already-approved issue" do
      issue = pending_issue
      issue.update_column(:status, "approved")

      result = approval_for(issue, actor: approver).approve!
      expect(result.ok?).to be(false)
    end
  end

  describe "#reject!" do
    it "moves pending_approval to rejected, stores the reason, and logs it" do
      issue = pending_issue

      result = approval_for(issue, actor: approver).reject!(reason: "wrong branch")

      expect(result.ok?).to be(true)
      issue.reload
      expect(issue).to be_rejected
      expect(issue.rejected_by).to eq(approver)
      expect(issue.rejected_at).to be_present
      expect(issue.rejection_reason).to eq("wrong branch")

      log = AuditLog.for_auditable(issue).find_by(action: "reject")
      expect(log.metadata["reason"]).to eq("wrong branch")
    end

    it "requires a non-blank reason" do
      issue = pending_issue

      result = approval_for(issue, actor: approver).reject!(reason: "   ")
      expect(result.ok?).to be(false)
      expect(issue.reload).to be_pending_approval
    end

    it "blocks self-rejection by the submitter" do
      issue = pending_issue(submitted_by: requester)

      result = approval_for(issue, actor: requester).reject!(reason: "changed my mind")
      expect(result.ok?).to be(false)
      expect(issue.reload).to be_pending_approval
    end

    it "never affects inventory" do
      issue = pending_issue
      approval_for(issue, actor: approver).reject!(reason: "no")
      expect(issue.inventory_movements.count).to eq(0)
    end
  end
end
