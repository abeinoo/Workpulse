require "rails_helper"

# Warehouse Architecture — PR 2: Inventory::WarehouseManager (create / update /
# delete). Two-connection races live in warehouse_manager_concurrency_spec.rb.
RSpec.describe Inventory::WarehouseManager do
  let(:business)       { create(:business) }
  let(:other_business) { create(:business) }
  # access_all_warehouses: creating a warehouse requires it on top of manage_inventory (PR 5, D4).
  let(:manager_user)   { user_with_stock_permissions(business, :view_inventory, :manage_inventory, :access_all_warehouses) }
  let(:viewer)         { user_with_stock_permissions(business, :view_inventory) }
  let(:manager)        { described_class.new(actor: manager_user) }
  let(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let(:product)        { business.products.create!(name: "Shampoo", sku: "SH-#{SecureRandom.hex(2)}", average_cost_price: 5) }

  def audits_for(warehouse, action) = AuditLog.where(auditable_type: "Warehouse", auditable_id: warehouse.id, action: action)
  def error_for(code) = I18n.t("inventory.warehouses.errors.#{code}")
  # A branch warehouse through its only creation path (as the branch lifecycle does).
  def provisioned(branch) = Warehouse.transaction { manager.provision_branch_warehouse(branch: branch) }.warehouse

  describe "#create" do
    it "creates a central warehouse without a branch, with an audit entry" do
      result = manager.create(kind: "central", name: "Main", description: "HQ stock")

      expect(result).to be_ok
      warehouse = result.warehouse.reload
      expect(warehouse).to be_kind_central
      expect(warehouse.branch_id).to be_nil
      expect(warehouse.business_id).to eq(business.id)

      audit = audits_for(warehouse, "create").sole
      expect(audit.actor).to eq(manager_user)
      expect(audit.business_id).to eq(business.id)
      expect(audit.changes_json).to include("name" => [ nil, "Main" ], "kind" => [ nil, "central" ], "branch_id" => [ nil, nil ])
      expect(audit.metadata).to include("business_id" => business.id, "kind" => "central", "branch_id" => nil)
    end

    it "allows several central warehouses in one business" do
      expect(manager.create(kind: "central", name: "Central A")).to be_ok
      expect(manager.create(kind: "central", name: "Central B")).to be_ok
      expect(business.warehouses.kind_central.count).to eq(2)
    end

    it "requires an explicit, known kind" do
      [ nil, "", "laundry" ].each do |kind|
        result = manager.create(kind: kind, name: "No kind")
        expect(result).not_to be_ok
        expect(result.code).to eq(:kind_required)
      end
      expect(Warehouse.count).to eq(0)
    end

    # Branch warehouses come only from provision_branch_warehouse (branch
    # lifecycle / backfill); the ordinary creation path refuses them outright.
    describe "never creates a branch warehouse" do
      def expect_refused(result)
        expect(result).not_to be_ok
        expect(result.code).to eq(:branch_warehouse_requires_provisioning)
        expect(result.error).to eq(error_for(:branch_warehouse_requires_provisioning))
        expect(Warehouse.count).to eq(0)
        expect(AuditLog.where(auditable_type: "Warehouse")).to be_empty
      end

      it "refuses kind branch for a sales branch of the actor's business" do
        expect_refused(manager.create(kind: "branch", name: "#{sales_branch.name} – المخزن", branch_id: sales_branch.id))
      end

      it "refuses kind branch without a branch" do
        expect_refused(manager.create(kind: "branch", name: "Orphan"))
        expect_refused(manager.create(kind: :branch, name: "Orphan"))
      end

      it "refuses a central warehouse that names a branch" do
        expect_refused(manager.create(kind: "central", name: "Central", branch_id: sales_branch.id))
      end

      %w[laundry headquarters maintenance warehouse other].each do |type|
        it "refuses a #{type} branch" do
          branch = create(:branch, business: business, branch_type: type)
          expect_refused(manager.create(kind: "branch", name: "X", branch_id: branch.id))
        end
      end

      it "refuses a branch of another business" do
        foreign = create(:branch, business: other_business, branch_type: "sales")
        expect_refused(manager.create(kind: "branch", name: "X", branch_id: foreign.id))
      end

      it "leaves branch provisioning as the way to get a branch warehouse" do
        expect_refused(manager.create(kind: "branch", name: "X", branch_id: sales_branch.id))

        result = Warehouse.transaction { manager.provision_branch_warehouse(branch: sales_branch) }
        expect(result).to be_ok
        expect(result.warehouse.reload).to have_attributes(kind: "branch", branch_id: sales_branch.id,
                                                           name: "#{sales_branch.name} – المخزن")
        expect(Warehouse.where(branch_id: sales_branch.id).count).to eq(1)
      end
    end

    it "rejects an invalid status" do
      expect(manager.create(kind: "central", name: "X", status: "archived").code).to eq(:status_invalid)
    end

    it "refuses an actor without manage_inventory" do
      result = described_class.new(actor: viewer).create(kind: "central", name: "X")

      expect(result.code).to eq(:not_authorized)
      expect(Warehouse.count).to eq(0)
    end

    it "refuses manage_inventory alone — creation needs access_all_warehouses too (D4)" do
      manage_only = user_with_stock_permissions(business, :view_inventory, :manage_inventory)
      result = described_class.new(actor: manage_only).create(kind: "central", name: "X")

      expect(result.code).to eq(:not_authorized)
      expect(Warehouse.count).to eq(0)
      expect(AuditLog.where(auditable_type: "Warehouse")).to be_empty
    end

    it "writes nothing when the audit entry cannot be recorded" do
      fail_audit_writes!(:create)
      result = manager.create(kind: "central", name: "Unaudited")

      expect(result.code).to eq(:audit_failed)
      expect(Warehouse.count).to eq(0)
    end
  end

  describe "#update" do
    let!(:central)  { manager.create(kind: "central", name: "Central", description: "old").warehouse }
    let!(:owned)    { provisioned(sales_branch) }

    it "updates the permitted attributes and audits before/after values" do
      result = manager.update(warehouse_id: central.id, name: "Central (renamed)", description: "new", status: "inactive")

      expect(result).to be_ok
      expect(central.reload).to have_attributes(name: "Central (renamed)", description: "new", status: "inactive", kind: "central")
      audit = audits_for(central, "update").sole
      expect(audit.changes_json).to eq("name" => [ "Central", "Central (renamed)" ], "description" => [ "old", "new" ],
                                       "status" => [ "active", "inactive" ])
      expect(audit.metadata).to include("business_id" => business.id, "kind" => "central")
    end

    it "changes only the attributes given, and writes no audit entry when nothing changed" do
      expect(manager.update(warehouse_id: central.id, description: "only this")).to be_ok
      expect(central.reload).to have_attributes(name: "Central", description: "only this")

      expect { expect(manager.update(warehouse_id: central.id, name: "Central")).to be_ok }
        .not_to change(AuditLog.where(action: "update"), :count)
    end

    it "does not accept structural attributes at all" do
      expect { manager.update(warehouse_id: owned.id, kind: "central") }.to raise_error(ArgumentError)
      expect { manager.update(warehouse_id: owned.id, branch_id: nil) }.to raise_error(ArgumentError)
      expect { manager.update(warehouse_id: owned.id, business_id: other_business.id) }.to raise_error(ArgumentError)
      expect(owned.reload).to have_attributes(kind: "branch", branch_id: sales_branch.id, business_id: business.id)
    end

    it "leaves the warehouse unchanged when validation fails" do
      result = manager.update(warehouse_id: central.id, name: "")

      expect(result.code).to eq(:invalid)
      expect(central.reload.name).to eq("Central")
      expect(audits_for(central, "update")).to be_empty
    end

    it "rejects an invalid status without touching the row" do
      expect(manager.update(warehouse_id: central.id, status: "archived").code).to eq(:status_invalid)
      expect(central.reload.status).to eq("active")
    end

    it "keeps a branch warehouse editable after its branch stops being a sales branch" do
      sales_branch.update!(branch_type: "laundry")

      expect(manager.update(warehouse_id: owned.id, name: "Still owned")).to be_ok
      expect(owned.reload).to have_attributes(name: "Still owned", branch_id: sales_branch.id, kind: "branch")
    end

    it "cannot reach another business's warehouse" do
      foreign = other_business.warehouses.create!(name: "Foreign")

      expect(manager.update(warehouse_id: foreign.id, name: "Mine now").code).to eq(:not_found)
      expect(foreign.reload.name).to eq("Foreign")
    end

    it "keeps a warehouse-scoped user to their assigned warehouses" do
      scoped_user = user_with_stock_permissions(business, :view_inventory, :manage_inventory)
      WarehouseAssignment.create!(user: scoped_user, warehouse: owned)

      expect(described_class.new(actor: scoped_user).update(warehouse_id: central.id, name: "X").code).to eq(:not_found)
      expect(described_class.new(actor: scoped_user).update(warehouse_id: owned.id, name: "Y")).to be_ok
    end

    it "refuses an actor without manage_inventory" do
      expect(described_class.new(actor: viewer).update(warehouse_id: central.id, name: "X").code).to eq(:not_authorized)
      expect(central.reload.name).to eq("Central")
    end

    it "rolls the change back when the audit entry cannot be recorded" do
      fail_audit_writes!(:update)

      expect(manager.update(warehouse_id: central.id, name: "Lost").code).to eq(:audit_failed)
      expect(central.reload.name).to eq("Central")
    end
  end

  describe "structural identity (model rule behind every write path)" do
    let!(:central) { manager.create(kind: "central", name: "Central").warehouse }
    let!(:owned)   { provisioned(sales_branch) }

    it "never re-parents a branch warehouse" do
      other_branch = create(:branch, business: business, branch_type: "sales")
      owned.branch = other_branch

      expect(owned).not_to be_valid
      expect(owned.errors.of_kind?(:branch_id, :immutable)).to be(true)
    end

    it "never turns a branch warehouse central, or a central warehouse into a branch warehouse" do
      owned.assign_attributes(kind: "central", branch: nil)
      expect(owned).not_to be_valid
      expect(owned.errors.of_kind?(:kind, :immutable)).to be(true)

      central.assign_attributes(kind: "branch", branch: create(:branch, business: business, branch_type: "sales"))
      expect(central).not_to be_valid
      expect(central.errors.of_kind?(:kind, :immutable)).to be(true)
    end

    it "never moves a warehouse to another business" do
      central.business = other_business

      expect(central).not_to be_valid
      expect(central.errors.of_kind?(:business_id, :immutable)).to be(true)
    end

    it "still lets an unclassified warehouse be classified (the later, explicit step)" do
      legacy = business.warehouses.create!(name: "Legacy")
      legacy.kind = "central"

      expect(legacy).to be_valid
    end
  end

  describe "#destroy" do
    let(:warehouse) { manager.create(kind: "central", name: "Spare").warehouse }
    let(:branch)    { sales_branch }

    def destroy(target = warehouse, reason: "Created by mistake") = manager.destroy(warehouse_id: target.id, reason: reason)

    def movement!(direction, quantity, target = warehouse)
      InventoryMovement.create!(business: business, product: product, warehouse: target, direction: direction,
                                reason: direction == :in ? :opening_balance : :adjustment, quantity: quantity,
                                unit_cost: 5, occurred_on: Date.new(2026, 1, 1))
    end

    def expect_refused(result, *blockers)
      expect(result).not_to be_ok
      expect(result.code).to eq(:in_use)
      expect(result.blockers).to include(*blockers)
      expect(Warehouse.exists?(warehouse.id)).to be(true)
      expect(audits_for(warehouse, "destroy")).to be_empty
    end

    it "deletes a genuinely empty warehouse and audits a snapshot with the reason" do
      result = destroy

      expect(result).to be_ok
      expect(Warehouse.exists?(warehouse.id)).to be(false)
      audit = audits_for(warehouse, "destroy").sole
      expect(audit.actor).to eq(manager_user)
      expect(audit.metadata).to include("business_id" => business.id, "kind" => "central", "branch_id" => nil,
                                        "name" => "Spare", "status" => "active", "reason" => "Created by mistake")
    end

    it "deletes an empty branch warehouse and records its branch" do
      owned = provisioned(branch)

      expect(destroy(owned)).to be_ok
      expect(audits_for(owned, "destroy").sole.metadata).to include("kind" => "branch", "branch_id" => branch.id)
      expect(Branch.exists?(branch.id)).to be(true)
    end

    it "requires a reason" do
      expect(destroy(reason: "  ").code).to eq(:reason_required)
      expect(Warehouse.exists?(warehouse.id)).to be(true)
    end

    it "refuses a warehouse holding stock" do
      movement!(:in, 5)
      expect_refused(destroy, :stock_on_hand, :inventory_movements)
      expect(product.stock_in(warehouse)).to eq(5)
    end

    it "refuses a warehouse with movement history even when its balance is zero" do
      movement!(:in, 5)
      movement!(:out, 5)
      result = destroy

      expect_refused(result, :inventory_movements)
      expect(result.blockers).not_to include(:stock_on_hand)
      expect(InventoryMovement.where(warehouse_id: warehouse.id).count).to eq(2)
    end

    it "refuses a warehouse with a stock issue (even a draft)" do
      business.stock_issues.create!(warehouse: warehouse, branch: branch, issued_on: Date.new(2026, 1, 2))
      expect_refused(destroy, :stock_issues)
    end

    it "refuses a warehouse with a reservation (an approved stock issue)" do
      movement!(:in, 5)
      issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.new(2026, 1, 2))
      issue.items.build(product: product, quantity: 2)
      save_stock_issue_in_status!(issue, :approved)

      expect_refused(destroy, :stock_issues)
      expect(issue.reload).to be_approved
    end

    it "refuses a warehouse with a goods receipt" do
      receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.new(2026, 1, 3))
      receipt.items.build(product: product, quantity: 3, unit_cost: 5)
      expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok

      expect_refused(destroy, :goods_receipts)
    end

    it "refuses a warehouse with a stock adjustment" do
      adjustment = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.new(2026, 1, 4),
                                                    reason: "manual_correction", adjustment_number: "ADJ-#{SecureRandom.hex(2)}")
      adjustment.items.build(product: product, quantity_difference: 1, unit_cost: 5)
      adjustment.save!

      expect_refused(destroy, :stock_adjustments)
    end

    it "refuses a warehouse with a stock count" do
      counter = user_with_stock_permissions(business, :view_inventory, :manage_stock_counts)
      movement!(:in, 2) # a count needs at least one product in the warehouse
      expect(Inventory::StockCountCreator.new(actor: counter, warehouse_id: warehouse.id, counted_on: Date.new(2026, 1, 5)).call).to be_ok

      expect_refused(destroy, :stock_counts)
    end

    it "refuses both ends of a stock transfer" do
      destination = manager.create(kind: "central", name: "Destination").warehouse
      movement!(:in, 5)
      transfer = business.stock_transfers.build(source_warehouse: warehouse, destination_warehouse: destination,
                                                transferred_on: Date.new(2026, 1, 6))
      transfer.items.build(product: product, quantity: 5)
      expect(Inventory::StockTransferPoster.new(transfer).call).to be_ok

      expect_refused(destroy, :stock_transfers)
      expect(destroy(destination).blockers).to include(:stock_transfers, :stock_on_hand)
      expect(Warehouse.exists?(destination.id)).to be(true)
    end

    it "refuses a warehouse named by a purchase request or a purchase request line" do
      supplier = business.suppliers.create!(name: "Acme")
      request = business.purchase_requests.build(warehouse: warehouse, supplier: supplier)
      request.items.build(product: product, quantity: 1, unit_price: 1, source_warehouse: warehouse)
      request.save!

      expect_refused(destroy, :purchase_requests, :purchase_request_items)
    end

    it "refuses a warehouse with product thresholds, user access or supply links" do
      ProductWarehouseSetting.create!(product: product, warehouse: warehouse, low_stock_level: 1, reorder_quantity: 2)
      WarehouseAssignment.create!(user: viewer, warehouse: warehouse)
      WarehouseBranchSupply.create!(business: business, warehouse: warehouse, branch: branch, active: false)

      expect_refused(destroy, :product_warehouse_settings, :warehouse_assignments, :warehouse_branch_supplies)
      expect(WarehouseAssignment.where(warehouse_id: warehouse.id).count).to eq(1)
    end

    it "explains every blocker in the error message" do
      movement!(:in, 5)
      result = destroy

      expect(result.error).to include(I18n.t("inventory.warehouses.references.stock_on_hand"),
                                      I18n.t("inventory.warehouses.references.inventory_movements"))
    end

    it "falls back to the foreign keys when a reference slips past the checks" do
      ProductWarehouseSetting.create!(product: product, warehouse: warehouse, low_stock_level: 1, reorder_quantity: 2)
      allow(manager).to receive(:blockers_for).and_return([], [ :product_warehouse_settings ])

      result = destroy
      expect(result.code).to eq(:in_use)
      expect(result.blockers).to eq([ :product_warehouse_settings ])
      expect(Warehouse.exists?(warehouse.id)).to be(true)
      expect(ProductWarehouseSetting.where(warehouse_id: warehouse.id).count).to eq(1)
      expect(audits_for(warehouse, "destroy")).to be_empty
    end

    it "cannot reach another business's warehouse" do
      foreign = other_business.warehouses.create!(name: "Foreign")

      expect(destroy(foreign).code).to eq(:not_found)
      expect(Warehouse.exists?(foreign.id)).to be(true)
    end

    it "refuses an actor without manage_inventory" do
      expect(described_class.new(actor: viewer).destroy(warehouse_id: warehouse.id, reason: "x").code).to eq(:not_authorized)
      expect(Warehouse.exists?(warehouse.id)).to be(true)
    end

    it "keeps the warehouse when the audit entry cannot be recorded" do
      fail_audit_writes!(:destroy)

      expect(destroy.code).to eq(:audit_failed)
      expect(Warehouse.exists?(warehouse.id)).to be(true)
    end
  end

  describe "REFERENCES" do
    it "covers every foreign key that references warehouses" do
      conn = ActiveRecord::Base.connection
      keyed = conn.tables.flat_map { |table| conn.foreign_keys(table) }
                  .select { |fk| fk.to_table == "warehouses" }
                  .map { |fk| [ fk.from_table, fk.column ] }

      covered = described_class::REFERENCES.values.flat_map do |relation|
        sql = relation.call(0).to_sql
        keyed.select { |table, column| sql.include?(%("#{table}"."#{column}")) }
      end

      expect(keyed - covered).to be_empty
    end
  end
end
