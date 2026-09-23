require "rails_helper"

RSpec.describe Inventory::PurchaseRequestApproval, type: :model do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let(:requester)  { create(:user, business: business) }
  let(:approver)   { create(:user, business: business) }
  let(:supplier)   { business.suppliers.create!(name: "Acme") }
  let(:product)    { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 100) }

  def draft_request(created_by: requester)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: created_by)
    pr.items.build(product: product, quantity: 10, unit_price: 100)
    pr.save!
    pr
  end

  def approval_for(request, actor:)
    described_class.new(purchase_request_id: request.id, actor: actor)
  end

  describe "#submit!" do
    it "moves draft to pending_approval and logs the transition" do
      request = draft_request
      result = approval_for(request, actor: requester).submit!

      expect(result.ok?).to be(true)
      expect(request.reload).to be_pending_approval
      expect(request.submitted_by).to eq(requester)
      log = AuditLog.for_auditable(request).find_by(action: "submit_for_approval")
      expect(log).to be_present
      expect(log.changes_json["status"]).to eq(%w[draft pending_approval])
    end

    it "refuses to submit an already-pending request" do
      request = draft_request
      request.update_column(:status, "pending_approval")

      result = approval_for(request, actor: requester).submit!
      expect(result.ok?).to be(false)
    end
  end

  describe "#approve!" do
    it "moves pending_approval to approved and logs it" do
      request = draft_request
      request.update_column(:status, "pending_approval")

      result = approval_for(request, actor: approver).approve!

      expect(result.ok?).to be(true)
      expect(request.reload).to be_approved
      expect(request.approved_by).to eq(approver)
    end

    it "blocks the submitter from approving their own request" do
      request = draft_request
      request.update_columns(status: "pending_approval", submitted_by_id: requester.id)

      result = approval_for(request, actor: requester).approve!
      expect(result.ok?).to be(false)
      expect(request.reload).to be_pending_approval
    end

    it "allows the business owner to approve even their own submission" do
      request = draft_request(created_by: owner)
      request.update_columns(status: "pending_approval", submitted_by_id: owner.id)

      result = approval_for(request, actor: owner).approve!
      expect(result.ok?).to be(true)
    end

    it "refuses to approve a draft request" do
      request = draft_request
      result = approval_for(request, actor: approver).approve!
      expect(result.ok?).to be(false)
    end
  end

  describe "#reject!" do
    it "moves pending_approval to rejected with a reason" do
      request = draft_request
      request.update_column(:status, "pending_approval")

      result = approval_for(request, actor: approver).reject!(reason: "Price too high")

      expect(result.ok?).to be(true)
      expect(request.reload).to be_rejected
      expect(request.rejection_reason).to eq("Price too high")
    end

    it "requires a non-blank reason" do
      request = draft_request
      request.update_column(:status, "pending_approval")

      result = approval_for(request, actor: approver).reject!(reason: "  ")
      expect(result.ok?).to be(false)
      expect(request.reload).to be_pending_approval
    end
  end
end
