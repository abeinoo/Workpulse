require "rails_helper"

RSpec.describe StockIssuePolicy, type: :policy do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  let(:creator_role)  { create(:permission_role, business: business, permissions: %w[view_inventory manage_stock_issues]) }
  let(:creator)       { create(:user, business: business, permission_role: creator_role) }
  let(:approver_role) { create(:permission_role, business: business, permissions: %w[view_inventory approve_stock_issues]) }
  let(:approver)      { create(:user, business: business, permission_role: approver_role) }
  let(:confirmer_role) { create(:permission_role, business: business, permissions: %w[view_inventory confirm_stock_issues]) }
  let(:confirmer)      { create(:user, business: business, permission_role: confirmer_role) }
  let(:viewer_role)   { create(:permission_role, business: business, permissions: %w[view_inventory]) }
  let(:viewer)        { create(:user, business: business, permission_role: viewer_role) }

  def build_issue(status: "draft")
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    i.items.build(product: product, quantity: 1) unless status == "draft"
    save_stock_issue_in_status!(i, status).reload
  end

  describe "#update? / #destroy? / #submit?" do
    it "allows the creator-permission holder to edit/submit/destroy a draft" do
      issue = build_issue(status: "draft")
      policy = described_class.new(creator, issue)
      expect(policy.update?).to be true
      expect(policy.destroy?).to be true
      expect(policy.submit?).to be true
    end

    it "allows editing a pending issue (Edit Request) but not deleting or re-submitting it" do
      issue = build_issue(status: "pending_approval")
      policy = described_class.new(creator, issue)
      expect(policy.update?).to be true
      expect(policy.destroy?).to be false
      expect(policy.submit?).to be false
    end

    it "allows editing an approved issue (Edit Request), but not deleting or submitting it" do
      policy = described_class.new(creator, build_issue(status: "approved"))
      expect(policy.update?).to be true
      expect(policy.destroy?).to be false
      expect(policy.submit?).to be false
    end

    it "blocks editing once issued, rejected, or cancelled" do
      %w[issued rejected cancelled].each do |status|
        expect(described_class.new(creator, build_issue(status: status)).update?).to be(false), status
      end
    end

    it "blocks approvers, confirmers, and viewers from editing an approved issue" do
      issue = build_issue(status: "approved")
      [ approver, confirmer, viewer ].each do |user|
        expect(described_class.new(user, issue).update?).to be(false)
      end
    end

    it "blocks a plain viewer and an approver-only user from editing a pending issue" do
      issue = build_issue(status: "pending_approval")
      expect(described_class.new(viewer, issue).update?).to be false
      expect(described_class.new(approver, issue).update?).to be false
    end

    it "blocks a plain viewer from editing a draft" do
      issue = build_issue(status: "draft")
      expect(described_class.new(viewer, issue).update?).to be false
    end
  end

  describe "#approve? / #reject?" do
    it "requires approve_stock_issues and pending_approval status" do
      issue = build_issue(status: "pending_approval")
      expect(described_class.new(approver, issue).approve?).to be true
      expect(described_class.new(approver, issue).reject?).to be true
      expect(described_class.new(creator, issue).approve?).to be false
    end

    it "refuses once no longer pending" do
      issue = build_issue(status: "approved")
      expect(described_class.new(approver, issue).approve?).to be false
    end
  end

  describe "#confirm?" do
    it "requires confirm_stock_issues and approved status — separate permission from approve" do
      issue = build_issue(status: "approved")
      expect(described_class.new(confirmer, issue).confirm?).to be true
      expect(described_class.new(approver, issue).confirm?).to be false
    end

    it "refuses while pending_approval" do
      issue = build_issue(status: "pending_approval")
      expect(described_class.new(confirmer, issue).confirm?).to be false
    end
  end

  describe "#cancel?" do
    it "allows cancelling a draft or approved issue with create permission" do
      expect(described_class.new(creator, build_issue(status: "draft")).cancel?).to be true
      expect(described_class.new(creator, build_issue(status: "approved")).cancel?).to be true
    end

    it "refuses once issued" do
      expect(described_class.new(creator, build_issue(status: "issued")).cancel?).to be false
    end

    it "refuses while pending_approval" do
      expect(described_class.new(creator, build_issue(status: "pending_approval")).cancel?).to be false
    end
  end

  describe "#void?" do
    it "is only true once issued" do
      expect(described_class.new(creator, build_issue(status: "issued")).void?).to be true
      expect(described_class.new(creator, build_issue(status: "approved")).void?).to be false
      expect(described_class.new(creator, build_issue(status: "draft")).void?).to be false
    end
  end
end
