require "rails_helper"

# Warehouse Access decisions 4–7 (Phase 2, D/E): a branch manager's explicit
# assignment to their branch's warehouse is revoked when the manager is
# replaced, removed or deactivated, and when the branch is deactivated or
# reclassified from sales — atomically with the change and a fail-closed
# "branch_manager_change" audit entry. Nothing else is touched.
RSpec.describe OrganizationAccess::BranchManagerLifecycle do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:shubra)  { create(:branch, business: business, name: "Shubra", branch_type: "sales") }
  let!(:nasr)    { create(:branch, business: business, name: "Nasr", branch_type: "sales") }
  let!(:shubra_wh) { business.warehouses.create!(name: "Shubra WH", kind: "branch", branch: shubra) }
  let!(:nasr_wh)   { business.warehouses.create!(name: "Nasr WH", kind: "branch", branch: nasr) }
  let!(:central)   { business.warehouses.create!(name: "Central", kind: "central") }
  let(:previous_manager) { create(:user, business: business) }
  let(:new_manager)      { create(:user, business: business) }

  before do
    shubra.update_column(:branch_manager_id, previous_manager.id)
    # Explicit grants: the managed branch's warehouse, plus unrelated ones (12).
    [ shubra_wh, nasr_wh, central ].each { |w| WarehouseAssignment.create!(user: previous_manager, warehouse: w) }
  end

  def assigned(user = previous_manager) = WarehouseAssignment.where(user: user).order(:warehouse_id).pluck(:warehouse_id)
  def changes_logged = AuditLog.where(auditable: shubra, action: described_class::ACTION).order(:id)
  def update_branch(attributes) = OrganizationAccess::UpdateBranch.new(shubra.id, actor: owner, attributes: attributes).call

  shared_examples "revokes only the branch-warehouse assignment" do
    it "removes the explicit assignment to the branch's warehouse and nothing else (12)" do
      expect(assigned).to eq([ nasr_wh.id, central.id ].sort)
    end

    it "audits the removed assignment in the actor's name" do
      entry = AuditLog.where(auditable_type: "WarehouseAssignment", action: "destroy").last
      expect(entry.actor_id).to eq(owner.id)
      expect(entry.metadata).to include("user_id" => previous_manager.id, "warehouse_id" => shubra_wh.id)
    end
  end

  describe "manager replaced (7)" do
    before { expect(update_branch("branch_manager_id" => new_manager.id)).to be_ok }

    include_examples "revokes only the branch-warehouse assignment"

    it "records the change with branch, previous and new manager, actor and the revoked assignment" do
      entry = changes_logged.last
      expect(entry.actor_id).to eq(owner.id)
      expect(entry.changes_json).to eq("branch_manager_id" => [ previous_manager.id, new_manager.id ])
      expect(entry.metadata).to include(
        "branch_id" => shubra.id, "branch_name" => "Shubra", "change_type" => "manager_replaced",
        "previous_manager_id" => previous_manager.id, "new_manager_id" => new_manager.id,
        "revoked_warehouse_assignment" => { "user_id" => previous_manager.id, "warehouse_id" => shubra_wh.id }
      )
    end

    it "grants nothing to the new manager (only the automatic rule applies)" do
      expect(assigned(new_manager)).to be_empty
    end
  end

  describe "manager removed (8)" do
    before { expect(update_branch("branch_manager_id" => "")).to be_ok }

    include_examples "revokes only the branch-warehouse assignment"

    it "records a manager_removed change" do
      expect(changes_logged.last.metadata).to include("change_type" => "manager_removed", "new_manager_id" => nil)
    end
  end

  describe "manager assigned to a branch without one" do
    it "records manager_assigned and revokes nothing" do
      nasr_manager = create(:user, business: business)
      expect(OrganizationAccess::UpdateBranch.new(nasr.id, actor: owner, attributes: { "branch_manager_id" => nasr_manager.id }).call)
        .to be_ok

      entry = AuditLog.where(auditable: nasr, action: described_class::ACTION).last
      expect(entry.metadata).to include("change_type" => "manager_assigned", "revoked_warehouse_assignment" => nil)
      expect(assigned).to eq([ shubra_wh.id, nasr_wh.id, central.id ].sort)
    end
  end

  describe "manager account deactivated (9)" do
    context "through the status toggle" do
      before { OrganizationAccess::Accounts.toggle_active!(actor: owner, user: previous_manager) }

      include_examples "revokes only the branch-warehouse assignment"

      it "records manager_deactivated and keeps the branch's manager link (replacing it is a separate edit)" do
        expect(changes_logged.last.metadata).to include("change_type" => "manager_deactivated",
                                                        "previous_manager_id" => previous_manager.id)
        expect(shubra.reload.branch_manager_id).to eq(previous_manager.id)
      end
    end

    context "through the employee form's status field" do
      before do
        OrganizationAccess::Accounts.stage(actor: owner, user: previous_manager, attributes: { "active" => "0" })
        previous_manager.save!
      end

      include_examples "revokes only the branch-warehouse assignment"
    end

    it "does nothing for a deactivation nobody is attributed with (console / system save)" do
      previous_manager.update!(active: false)
      expect(assigned).to eq([ shubra_wh.id, nasr_wh.id, central.id ].sort)
    end
  end

  describe "branch deactivated (10)" do
    before do
      expect(OrganizationAccess::DeactivateBranch.new(shubra.id, actor: owner, reason: "Closed").call).to be_ok
    end

    include_examples "revokes only the branch-warehouse assignment"

    it "records branch_deactivated next to the deactivation itself" do
      expect(changes_logged.last.metadata).to include("change_type" => "branch_deactivated",
                                                      "previous_manager_id" => previous_manager.id,
                                                      "new_manager_id" => previous_manager.id)
      expect(AuditLog.where(auditable: shubra, action: "deactivate")).to exist
    end
  end

  describe "branch reclassified from sales (10)" do
    before { expect(update_branch("branch_type" => "headquarters")).to be_ok }

    include_examples "revokes only the branch-warehouse assignment"

    it "records branch_reclassified with both types" do
      expect(changes_logged.last.metadata).to include("change_type" => "branch_reclassified",
                                                      "previous_branch_type" => "sales",
                                                      "new_branch_type" => "headquarters")
    end
  end

  describe "atomicity (11)" do
    it "rolls the branch change and the revocation back together when the audit cannot be written" do
      allow(AuditLog).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
        raise ActiveRecord::RecordInvalid, AuditLog.new if kwargs[:action] == described_class::ACTION

        original.call(*args, **kwargs)
      end

      result = update_branch("branch_manager_id" => new_manager.id)

      expect(result).not_to be_ok
      expect(shubra.reload.branch_manager_id).to eq(previous_manager.id)
      expect(assigned).to eq([ shubra_wh.id, nasr_wh.id, central.id ].sort)
      expect(changes_logged).to be_empty
    end
  end

  describe "historical inventory records (13)" do
    it "leaves every movement and document of the branch warehouse unchanged" do
      product = business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
      receipt = business.goods_receipts.build(warehouse: shubra_wh, received_on: Date.current)
      receipt.items.build(product: product, quantity: 5, unit_cost: 10)
      Inventory::GoodsReceiptPoster.new(receipt).call
      before_movements = InventoryMovement.where(warehouse: shubra_wh).order(:id).map(&:attributes)
      before_receipt   = receipt.reload.attributes

      update_branch("branch_manager_id" => new_manager.id)

      expect(InventoryMovement.where(warehouse: shubra_wh).order(:id).map(&:attributes)).to eq(before_movements)
      expect(receipt.reload.attributes).to eq(before_receipt)
      expect(shubra_wh.reload).to be_active
    end
  end
end
