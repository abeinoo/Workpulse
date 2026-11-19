require "rails_helper"

# Inventory::WarehouseManager#classify — an existing UNCLASSIFIED warehouse
# (kind NULL) becomes central, or the branch warehouse of an active sales
# branch, once, with one audit entry. Two-connection races live in
# warehouse_manager_concurrency_spec.rb.
RSpec.describe Inventory::WarehouseManager, "#classify" do
  let(:business)       { create(:business) }
  let(:other_business) { create(:business) }
  let(:actor)          { user_with_stock_permissions(business, :view_inventory, :manage_inventory, :access_all_warehouses) }
  let(:manager)        { described_class.new(actor: actor) }
  let(:shubra)         { create(:branch, business: business, name: "Shubra", branch_type: "sales") }
  let!(:legacy)        { business.warehouses.create!(name: "المخزن الرئيسي", description: "HQ") } # like warehouse #1
  let(:product)        { business.products.create!(name: "Shampoo", sku: "SH-#{SecureRandom.hex(2)}", average_cost_price: 5) }

  def default_reason = "Owner decision: serves the Shubra branch"

  def classify(kind, branch_id: nil, warehouse: legacy, by: manager, reason: default_reason)
    by.classify(warehouse_id: warehouse.id, kind: kind, branch_id: branch_id, reason: reason)
  end

  def audits = AuditLog.where(auditable_type: "Warehouse", action: "classify")
  def error_for(code) = I18n.t("inventory.warehouses.errors.#{code}")

  def expect_refused(result, code)
    expect(result).not_to be_ok
    expect(result.code).to eq(code)
    expect(result.error).to eq(error_for(code))
    expect(legacy.reload).to have_attributes(kind: nil, branch_id: nil)
    expect(audits).to be_empty
  end

  describe "central" do
    it "sets kind central with no branch and writes one audit entry" do
      result = classify("central")

      expect(result).to be_ok
      expect(legacy.reload).to have_attributes(kind: "central", branch_id: nil, name: "المخزن الرئيسي",
                                               description: "HQ", status: "active", business_id: business.id)
      audit = audits.sole
      expect(audit).to have_attributes(actor_id: actor.id, auditable_id: legacy.id, business_id: business.id)
      expect(audit.changes_json).to eq("kind" => [ nil, "central" ], "branch_id" => [ nil, nil ])
      expect(audit.metadata).to include("business_id" => business.id, "kind" => "central", "branch_id" => nil,
                                        "name" => "المخزن الرئيسي", "reason" => default_reason)
    end

    it "refuses a central classification that names a branch" do
      expect_refused(classify("central", branch_id: shubra.id), :central_without_branch)
    end
  end

  describe "branch" do
    it "links the warehouse to an active sales branch and writes one audit entry" do
      result = classify("branch", branch_id: shubra.id)

      expect(result).to be_ok
      expect(legacy.reload).to have_attributes(kind: "branch", branch_id: shubra.id, name: "المخزن الرئيسي")
      expect(legacy.owning_branch).to eq(shubra)
      expect(audits.sole.changes_json).to eq("kind" => [ nil, "branch" ], "branch_id" => [ nil, shubra.id ])
      expect(audits.sole.metadata).to include("kind" => "branch", "branch_id" => shubra.id)
    end

    it "creates no warehouse" do
      expect { classify("branch", branch_id: shubra.id) }.not_to change(Warehouse, :count)
    end

    it "requires a branch" do
      expect_refused(classify("branch"), :branch_required)
      expect_refused(classify("branch", branch_id: ""), :branch_required)
    end

    it "refuses an unknown branch id" do
      expect_refused(classify("branch", branch_id: 0), :branch_not_found)
    end

    it "refuses another business's branch as not found" do
      foreign = create(:branch, business: other_business, branch_type: "sales")
      expect_refused(classify("branch", branch_id: foreign.id), :branch_not_found)
    end

    %w[laundry headquarters maintenance warehouse other].each do |type|
      it "refuses a #{type} branch" do
        branch = create(:branch, business: business, branch_type: type)
        expect_refused(classify("branch", branch_id: branch.id), :branch_not_sales)
      end
    end

    it "refuses an inactive sales branch" do
      shubra.update_column(:active, false)
      expect_refused(classify("branch", branch_id: shubra.id), :branch_inactive)
    end

    it "refuses a branch that already has a branch warehouse" do
      Branch.transaction { Inventory::BranchWarehouseProvisioning.provision!(branch: shubra, actor: actor) }
      expect_refused(classify("branch", branch_id: shubra.id), :branch_already_has_warehouse)
      expect(Warehouse.where(branch_id: shubra.id).count).to eq(1)
    end

    it "translates a unique-index violation (a lost race) into the same domain error" do
      provisioned = Branch.transaction { Inventory::BranchWarehouseProvisioning.provision!(branch: shubra, actor: actor) }
      # Simulate the race: the pre-check and the model's uniqueness check both miss it.
      allow(Warehouse).to receive(:exists?).and_call_original
      allow(Warehouse).to receive(:exists?).with(branch_id: shubra.id).and_return(false)
      allow_any_instance_of(Warehouse).to receive(:valid?).and_return(true)

      expect_refused(classify("branch", branch_id: shubra.id), :branch_already_has_warehouse)
      expect(Warehouse.where(branch_id: shubra.id).pluck(:id)).to eq([ provisioned.id ])
    end
  end

  describe "input and state" do
    it "requires a known kind" do
      [ nil, "", "laundry", "unclassified" ].each do |kind|
        expect_refused(classify(kind), :classification_kind_invalid)
      end
    end

    it "refuses an already classified warehouse — kind and branch never change" do
      central = business.warehouses.create!(name: "Central", kind: "central")
      branch_wh = Branch.transaction { Inventory::BranchWarehouseProvisioning.provision!(branch: shubra, actor: actor) }
      other = create(:branch, business: business, branch_type: "sales")

      expect(classify("branch", branch_id: other.id, warehouse: central).code).to eq(:already_classified)
      expect(classify("central", warehouse: branch_wh).code).to eq(:already_classified)
      expect(central.reload).to have_attributes(kind: "central", branch_id: nil)
      expect(branch_wh.reload).to have_attributes(kind: "branch", branch_id: shubra.id)

      expect(classify("central")).to be_ok
      expect(classify("branch", branch_id: other.id).code).to eq(:already_classified)
      expect(legacy.reload).to have_attributes(kind: "central", branch_id: nil)
      expect(audits.count).to eq(1)
    end

    it "refuses another business's warehouse as not found" do
      foreign = other_business.warehouses.create!(name: "Foreign")
      result = classify("central", warehouse: foreign)

      expect(result.code).to eq(:not_found)
      expect(foreign.reload.kind).to be_nil
    end

    it "refuses a warehouse outside the actor's warehouse access as not found" do
      reachable = business.warehouses.create!(name: "Reachable")
      actor.assigned_warehouses << reachable

      expect_refused(classify("central"), :not_found)
    end
  end

  describe "reason" do
    it "is required — missing, empty or whitespace-only refuses and writes nothing" do
      [ nil, "", "   \n\t " ].each do |reason|
        expect_refused(classify("central", reason: reason), :classification_reason_required)
      end
    end

    it "is checked for a branch classification too" do
      expect_refused(classify("branch", branch_id: shubra.id, reason: " "), :classification_reason_required)
      expect(Warehouse.where(branch_id: shubra.id)).to be_empty
    end

    it "refuses more than #{described_class::CLASSIFICATION_REASON_MAX_LENGTH} characters" do
      max = described_class::CLASSIFICATION_REASON_MAX_LENGTH
      result = classify("central", reason: "x" * (max + 1))

      expect(result.code).to eq(:classification_reason_too_long)
      expect(result.error).to eq(I18n.t("inventory.warehouses.errors.classification_reason_too_long", count: max))
      expect(legacy.reload.kind).to be_nil
      expect(audits).to be_empty
    end

    it "accepts exactly the maximum and stores it, stripped, with the actor and old / new values" do
      max = described_class::CLASSIFICATION_REASON_MAX_LENGTH
      reason = "r" * max
      expect(classify("branch", branch_id: shubra.id, reason: "  #{reason}  ")).to be_ok

      audit = audits.sole
      expect(audit).to have_attributes(actor_id: actor.id, auditable_type: "Warehouse", auditable_id: legacy.id,
                                       business_id: business.id, action: "classify")
      expect(audit.changes_json).to eq("kind" => [ nil, "branch" ], "branch_id" => [ nil, shubra.id ])
      expect(audit.metadata).to include("reason" => reason, "business_id" => business.id, "kind" => "branch",
                                        "branch_id" => shubra.id, "name" => legacy.name)
    end
  end

  describe "authorization" do
    it "refuses manage_inventory alone (classification is company-wide structure, like creation)" do
      by = described_class.new(actor: user_with_stock_permissions(business, :view_inventory, :manage_inventory))
      expect_refused(classify("central", by: by), :not_authorized)
    end

    it "refuses a viewer" do
      by = described_class.new(actor: user_with_stock_permissions(business, :view_inventory))
      expect_refused(classify("branch", branch_id: shubra.id, by: by), :not_authorized)
    end

    it "lets the owner classify" do
      owner = create(:user, :owner, business: business)
      expect(classify("central", by: described_class.new(actor: owner))).to be_ok
    end
  end

  describe "audit" do
    it "rolls the classification back when the audit entry cannot be written" do
      fail_audit_writes!(:classify)

      result = classify("branch", branch_id: shubra.id)
      expect(result.code).to eq(:audit_failed)
      expect(legacy.reload).to have_attributes(kind: nil, branch_id: nil)
      expect(Warehouse.where(branch_id: shubra.id)).to be_empty
    end

    it "rolls back only its own savepoint inside a caller's transaction" do
      fail_audit_writes!(:classify)

      Warehouse.transaction do
        expect(classify("central").code).to eq(:audit_failed)
        expect(Warehouse.where(id: legacy.id).pick(:kind)).to be_nil # the connection still works
      end
      expect(legacy.reload.kind).to be_nil
    end
  end

  it "leaves stock, movements and documents exactly as they were" do
    InventoryMovement.create!(business: business, product: product, warehouse: legacy, direction: :in,
                              reason: :opening_balance, quantity: 7, unit_cost: 5, occurred_on: Date.new(2026, 1, 1))
    receipt = business.goods_receipts.build(warehouse: legacy, received_on: Date.new(2026, 1, 2))
    receipt.items.build(product: product, quantity: 3, unit_cost: 5)
    receipt = Inventory::GoodsReceiptPoster.new(receipt).call.receipt
    movements = -> { InventoryMovement.where(warehouse_id: legacy.id).order(:id).map(&:attributes) }
    before_movements = movements.call
    before_receipt = receipt.reload.attributes

    expect(classify("branch", branch_id: shubra.id)).to be_ok

    expect(movements.call).to eq(before_movements)
    expect(receipt.reload.attributes).to eq(before_receipt)
    expect(product.stock_in(legacy.reload)).to eq(10)
  end

  describe "#classifiable_branches" do
    it "offers only active sales branches of the actor's business without a warehouse" do
      taken    = create(:branch, business: business, name: "Taken", branch_type: "sales")
      Branch.transaction { Inventory::BranchWarehouseProvisioning.provision!(branch: taken, actor: actor) }
      inactive = create(:branch, business: business, name: "Closed", branch_type: "sales").tap { |b| b.update_column(:active, false) }
      laundry  = create(:branch, business: business, name: "Wash", branch_type: "laundry")
      foreign  = create(:branch, business: other_business, name: "Foreign", branch_type: "sales")

      offered = manager.classifiable_branches
      expect(offered).to include(shubra)
      expect(offered).not_to include(taken, inactive, laundry, foreign)
    end
  end
end
