require "rails_helper"

# "تعيين الموظف المسؤول" on an approved / receivable Purchase Request — how a
# legacy request gets one (never automatically) and how it changes later.
RSpec.describe Inventory::PurchaseRequestResponsibleAssigner, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:confirmer) { create(:user, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 100) }
  let(:rami) { purchaser_with_custody(business, first_name: "Rami", balance: 1000) }
  let(:lina) { purchaser_with_custody(business, first_name: "Lina") }

  def approved_request(responsible: nil)
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: actor, responsible_employee: responsible)
    pr.items.build(product: product, quantity: 5, unit_price: 100)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def assign(request, user_id) = described_class.new(request.id, actor: actor, responsible_employee_id: user_id).call
  def message(key) = I18n.t("inventory.purchase_requests.errors.#{key}")

  def fund(request, amount: 100)
    Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: request.id, actor: actor,
      params: { amount: amount, source_kind: "company_cash", paid_on: Date.current }
    ).call.advance
  end

  it "assigns an eligible employee to a legacy request and audits it" do
    pr = approved_request
    expect(assign(pr, rami.id)).to be_ok

    expect(pr.reload.responsible_employee).to eq(rami)
    expect(AuditLog.where(auditable: pr, action: "assign_responsible_employee").sole)
      .to have_attributes(actor_id: actor.id, changes_json: { "responsible_employee_id" => [ nil, rami.id ] })
  end

  it "changes it while no funding advance is pending or confirmed" do
    pr = approved_request(responsible: rami)
    expect(assign(pr, lina.id)).to be_ok
    expect(AuditLog.where(auditable: pr, action: "assign_responsible_employee").sole.changes_json)
      .to eq("responsible_employee_id" => [ rami.id, lina.id ])
  end

  it "is locked by a recorded (posted) funding advance, and free again once it is reversed" do
    pr = approved_request(responsible: rami)
    advance = fund(pr)
    expect(advance).to be_confirmed
    expect(assign(pr, lina.id).error).to eq(message(:responsible_employee_locked))
    expect(pr.reload.responsible_employee).to eq(rami)

    Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: confirmer).reverse!(reason: "x")
    expect(assign(pr, lina.id)).to be_ok
  end

  it "is locked by a funding advance still pending from the old workflow until it is cancelled" do
    pr = approved_request(responsible: rami)
    old = old_pending_funding_advance(request: pr, amount: 40, actor: actor)
    expect(assign(pr, lina.id).error).to eq(message(:responsible_employee_locked))

    Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: old.id, actor: confirmer).cancel!(reason: "obsolete")
    expect(assign(pr, lina.id)).to be_ok
  end

  it "is not locked by a legacy advance (it funded nobody)" do
    pr = approved_request
    legacy_confirmed_advance(request: pr, amount: 50, actor: actor)
    expect(assign(pr, rami.id)).to be_ok
  end

  it "refuses an ineligible or blank employee, and a request that is not receivable" do
    pr = approved_request(responsible: rami)
    no_permission = create(:user, business: business).tap { |u| create(:custody_account, business: business, user: u) }

    expect(assign(pr, no_permission.id).error).to eq(message(:responsible_employee_ineligible))
    expect(assign(pr, nil).error).to eq(message(:responsible_employee_required))

    pr.update_column(:status, "draft")
    expect(assign(pr, lina.id).error).to eq(message(:responsible_employee_not_assignable))
    expect(pr.reload.responsible_employee).to eq(rami)
  end

  it "is a no-op for the same employee (no audit)" do
    pr = approved_request(responsible: rami)
    expect(assign(pr, rami.id)).to be_ok
    expect(AuditLog.where(auditable: pr, action: "assign_responsible_employee")).to be_empty
  end

  describe "policy" do
    def user_with(*permissions)
      role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions)
      create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    end

    it "needs approve_purchase_requests or manage_inventory, and a receivable request" do
      pr = approved_request
      allowed = ->(user, record = pr) { PurchaseRequestPolicy.new(user, record).assign_responsible_employee? }

      expect(allowed.(user_with("view_inventory", "approve_purchase_requests"))).to be(true)
      expect(allowed.(user_with("view_inventory", "manage_inventory"))).to be(true)
      expect(allowed.(user_with("view_inventory", "create_purchase_requests"))).to be(false)
      pr.update_column(:status, "draft")
      expect(allowed.(user_with("view_inventory", "approve_purchase_requests"), pr.reload)).to be(false)
    end
  end
end
