require "rails_helper"

RSpec.describe Inventory::PurchaseRequestBulkApproval, type: :model do
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:approver) do
    role = business.permission_roles.create!(name: "PR Approver", permissions: %w[view_inventory approve_purchase_requests])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:supplier) { business.suppliers.create!(name: "Acme") }
  let(:product)  { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 1) }

  def pending_request(total:, supplier: self.supplier, submitted_by: requester)
    pr = business.purchase_requests.build(supplier: supplier, created_by: submitted_by)
    pr.items.build(product: product, quantity: 1, unit_price: total)
    pr.save!
    pr.update_columns(status: "pending_approval", submitted_by_id: submitted_by.id, submitted_at: Time.current)
    pr
  end

  def bulk(ids, actor: approver)
    described_class.new(purchase_request_ids: ids, actor: actor).call
  end

  it "approves every selected request and returns the count and exact combined total" do
    prs = [ pending_request(total: 2200), pending_request(total: 242), pending_request(total: 600) ]

    result = bulk(prs.map(&:id))

    expect(result).to be_ok
    expect(result.approved_count).to eq(3)
    expect(result.total_amount).to eq(BigDecimal("3042"))
    expect(prs.map { |pr| pr.reload.status }).to all(eq("approved"))
    expect(prs.map { |pr| pr.reload.approved_by }).to all(eq(approver))
  end

  it "sums decimal totals exactly (no float drift)" do
    prs = [ pending_request(total: "0.1"), pending_request(total: "0.2") ]

    expect(bulk(prs.map(&:id)).total_amount).to eq(BigDecimal("0.3"))
  end

  it "writes one audit entry per request, tagged as a bulk approval" do
    prs = [ pending_request(total: 10), pending_request(total: 20) ]
    bulk(prs.map(&:id))

    prs.each do |pr|
      log = AuditLog.for_auditable(pr).find_by!(action: "approve")
      expect(log.metadata).to include("bulk_approval" => true, "batch_size" => 2)
    end
  end

  it "approves requests without a supplier" do
    prs = [ pending_request(total: 50, supplier: nil), pending_request(total: 70) ]

    result = bulk(prs.map(&:id))

    expect(result).to be_ok
    expect(prs.first.reload).to be_approved
    expect(prs.first.supplier_id).to be_nil
  end

  it "rejects an empty selection" do
    result = bulk([])

    expect(result).not_to be_ok
    expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.bulk_none_selected"))
  end

  it "fails the WHOLE batch when one request is no longer pending (no partial approval)" do
    a = pending_request(total: 100)
    b = pending_request(total: 200)
    c = pending_request(total: 300)
    # Another manager approved B after the page loaded.
    Inventory::PurchaseRequestApproval.new(purchase_request_id: b.id, actor: approver).approve!

    result = nil
    expect { result = bulk([ a.id, b.id, c.id ]) }.not_to change { AuditLog.where(action: "approve").count }

    expect(result).not_to be_ok
    expect(result.error).to include(b.request_number)
    expect(result.approved_count).to eq(0)
    expect(a.reload).to be_pending_approval
    expect(c.reload).to be_pending_approval
  end

  it "rolls back approvals already made in the batch when a later one fails" do
    a = pending_request(total: 100)
    b = pending_request(total: 200)
    allow_any_instance_of(Inventory::PurchaseRequestApproval).to receive(:approve!).and_wrap_original do |original, **kwargs|
      instance = original.receiver
      if instance.instance_variable_get(:@purchase_request_id) == b.id
        Inventory::PurchaseRequestApproval::Result.new(ok: false, error: "boom")
      else
        original.call(**kwargs)
      end
    end

    result = bulk([ a.id, b.id ])

    expect(result).not_to be_ok
    expect(a.reload).to be_pending_approval
    expect(b.reload).to be_pending_approval
  end

  it "refuses requests from another business without approving anything" do
    own     = pending_request(total: 100)
    foreign = create(:business).purchase_requests.build(supplier: nil).tap do |pr|
      pr.items.build(product: create(:business).products.create!(name: "X", sku: "X-1", average_cost_price: 1),
                     quantity: 1, unit_price: 1)
    end
    foreign.save!(validate: false)
    foreign.update_columns(status: "pending_approval")

    result = bulk([ own.id, foreign.id ])

    expect(result).not_to be_ok
    expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.bulk_unavailable"))
    expect(own.reload).to be_pending_approval
    expect(foreign.reload).to be_pending_approval
  end

  it "keeps the self-approval rule: a batch containing the approver's own request fails as a whole" do
    other = pending_request(total: 100)
    own   = pending_request(total: 200, submitted_by: approver)

    result = bulk([ other.id, own.id ])

    expect(result).not_to be_ok
    expect(result.error).to include(own.request_number)
    expect(other.reload).to be_pending_approval
  end

  it "rejects drafts" do
    draft = business.purchase_requests.build(supplier: supplier, created_by: requester)
    draft.items.build(product: product, quantity: 1, unit_price: 5)
    draft.save!

    expect(bulk([ draft.id ])).not_to be_ok
    expect(draft.reload).to be_draft
  end
end
