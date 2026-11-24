require "rails_helper"

# Product availability per warehouse — Phase 1, unit 3: the audited service
# that is the one writer of availability state.
RSpec.describe Inventory::ProductAvailabilityManager do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:nasr_wh) { business.warehouses.create!(name: "Nasr City WH", kind: "central") }
  let!(:foreign_wh) { other.warehouses.create!(name: "Foreign") }

  # Stale values in the retired product-level columns (as existing databases
  # still hold) must never be read or copied by this service.
  def product(name, sku, tracked: true, **attrs)
    business.products.create!({ name: name, sku: sku, initial_cost_price: 5, average_cost_price: 5, track_inventory: tracked }.merge(attrs))
            .tap { |p| write_retired_product_stock_columns!(p, low_stock_level: 10, reorder_quantity: 20, reorder_level: 10) }
  end
  let!(:shampoo) { product("Shampoo", "SH-1") }
  let!(:mask)    { product("Mask", "MK-1") }
  let!(:towel)   { product("Towel", "TW-1", tracked: false) }

  let(:manager_user) do
    user_with_stock_permissions(business, :view_inventory, :manage_product_availability).tap do |u|
      WarehouseAssignment.create!(user: u, warehouse: central)
    end
  end

  def service(actor = owner) = described_class.new(actor: User.find(actor.id))
  def audits(action) = AuditLog.where(action: action)
  def item(product, low: 3, reorder: 10, notify: true)
    { product_id: product.id, low_stock_level: low, reorder_quantity: reorder, receive_low_stock_notification: notify }
  end

  describe "#add_many" do
    it "adds products to ONE warehouse as Active with that warehouse's own settings, audited per pair" do
      result = service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo, low: 5, reorder: 15), item(mask, notify: false) ])

      expect(result).to be_ok
      rows = ProductWarehouseSetting.where(warehouse: nasr_wh).order(:product_id)
      expect(rows.map(&:status)).to eq(%w[active active])
      expect(rows.find_by(product: shampoo).attributes.slice("low_stock_level", "reorder_quantity", "receive_low_stock_notification"))
        .to eq("low_stock_level" => 5, "reorder_quantity" => 15, "receive_low_stock_notification" => true)
      expect(rows.find_by(product: mask).receive_low_stock_notification).to be(false)
      expect(rows.map(&:created_by_id).uniq).to eq([ owner.id ])
      expect(ProductWarehouseSetting.where(warehouse: central)).to be_empty # no other warehouse configured

      entries = audits("availability_add")
      expect(entries.count).to eq(2)
      expect(entries.map { |e| e.metadata["batch_id"] }.uniq.size).to eq(1)
      expect(entries.find_by(auditable: rows.find_by(product: shampoo)).changes_json)
        .to include("status" => [ nil, "active" ], "low_stock_level" => [ nil, "5.0" ])
    end

    it "never copies stale product-level values into a warehouse, and never touches them" do
      service.add_many(warehouse_id: nasr_wh.id, items: [ { product_id: shampoo.id } ])
      row = ProductWarehouseSetting.find_by!(product: shampoo, warehouse: nasr_wh)
      expect([ row.low_stock_level, row.reorder_quantity ]).to eq([ 0, 0 ])
      expect(retired_product_stock_columns(shampoo).slice("low_stock_level", "reorder_level", "reorder_quantity"))
        .to eq("low_stock_level" => 10, "reorder_level" => 10, "reorder_quantity" => 20)
    end

    it "skips and reports pairs that already have a row — Active or Inactive — without duplicating them" do
      service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo), item(mask) ])
      mask_row = ProductWarehouseSetting.find_by!(product: mask, warehouse: nasr_wh)
      service.deactivate(setting_id: mask_row.id, reason: "not used")

      result = service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo, low: 9), item(mask, low: 9) ])

      expect(result).to be_ok
      expect(result.records).to be_empty
      expect(result.skipped.map(&:product_id)).to contain_exactly(shampoo.id, mask.id)
      expect(ProductWarehouseSetting.where(warehouse: nasr_wh).count).to eq(2)
      expect(mask_row.reload).to be_status_inactive # skipped, not silently reactivated
    end

    it "is all-or-nothing: one invalid item creates nothing" do
      result = service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo), item(mask, low: -2) ])
      expect(result.error).to eq(:invalid_quantity)
      expect(ProductWarehouseSetting.count).to eq(0)
      expect(audits("availability_add")).to be_empty
    end

    it "rolls the whole batch back when an audit entry cannot be written" do
      fail_audit_writes!(:availability_add, skip: 1)
      result = service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo), item(mask) ])
      expect(result.error).to eq(:audit_failed)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "refuses a product whose stock quantity is not tracked (no new availability rows, 2026-11-20)" do
      result = service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo), { product_id: towel.id } ])
      expect(result).to have_attributes(error: :untracked_product, record: towel)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "refuses invalid input" do
      expect(service.add_many(warehouse_id: nasr_wh.id, items: []).error).to eq(:no_items)
      expect(service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo), item(shampoo) ]).error).to eq(:duplicate_product)
      expect(service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo, low: -1) ]).error).to eq(:invalid_quantity)
      expect(service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo, low: "abc") ]).error).to eq(:invalid_quantity)
    end

    it "refuses another business's or archived products" do
      foreign = other.products.create!(name: "F", sku: "F-1", initial_cost_price: 1, average_cost_price: 1)
      archived = product("Old", "OLD-1").tap { |p| p.update!(active: false) }
      [ foreign, archived ].each do |refused|
        expect(service.add_many(warehouse_id: nasr_wh.id, items: [ item(refused) ]).error).to eq(:invalid_product)
      end
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "refuses an inactive warehouse and another business's warehouse" do
      nasr_wh.update_column(:status, "inactive")
      expect(service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo) ]).error).to eq(:inactive_warehouse)
      expect(service.add_many(warehouse_id: foreign_wh.id, items: [ item(shampoo) ]).error).to eq(:not_authorized)
    end
  end

  describe "authorization" do
    it "a scoped holder manages its own warehouse only" do
      expect(service(manager_user).add_many(warehouse_id: central.id, items: [ item(shampoo) ])).to be_ok
      expect(service(manager_user).add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo) ]).error).to eq(:not_authorized)
    end

    it "manage_products / manage_inventory without manage_product_availability is refused" do
      user = user_with_stock_permissions(business, :view_inventory, :manage_products, :manage_inventory)
      expect(service(user).add_many(warehouse_id: central.id, items: [ item(shampoo) ]).error).to eq(:not_authorized)
    end

    it "every call refuses a pair outside the actor's scope or business" do
      service.add_many(warehouse_id: nasr_wh.id, items: [ item(shampoo) ])
      nasr_row = ProductWarehouseSetting.find_by!(warehouse: nasr_wh)
      foreign_row = other.products.create!(name: "F", sku: "F-1", initial_cost_price: 1, average_cost_price: 1)
                         .product_warehouse_settings.create!(warehouse: foreign_wh, low_stock_level: 1, reorder_quantity: 1)

      scoped = service(manager_user)
      expect(scoped.update(setting_id: nasr_row.id, low_stock_level: 1, reorder_quantity: 1, receive_low_stock_notification: true).error)
        .to eq(:not_authorized)
      expect(scoped.deactivate(setting_id: nasr_row.id, reason: "x").error).to eq(:not_authorized)
      expect(scoped.dependencies(setting_id: nasr_row.id).error).to eq(:not_authorized)
      expect(service.deactivate(setting_id: foreign_row.id, reason: "x").error).to eq(:not_authorized)
      expect(nasr_row.reload).to be_status_active
      expect(foreign_row.reload).to be_status_active
    end

    it "an unassigned holder reaches nothing once the business is fail-closed" do
      user = user_with_stock_permissions(business, :view_inventory, :manage_product_availability)
      store_warehouse_access_fail_closed!(business)
      expect(service(user).add_many(warehouse_id: central.id, items: [ item(shampoo) ]).error).to eq(:not_authorized)
    end
  end

  describe "#update" do
    let!(:row) do
      service.add_many(warehouse_id: central.id, items: [ item(shampoo, low: 10, reorder: 20) ])
      ProductWarehouseSetting.find_by!(product: shampoo, warehouse: central)
    end

    it "changes an Active pair's settings and audits before / after" do
      result = service.update(setting_id: row.id, low_stock_level: 12, reorder_quantity: 20, receive_low_stock_notification: false)
      expect(result).to be_ok
      expect(row.reload.attributes.slice("low_stock_level", "receive_low_stock_notification"))
        .to eq("low_stock_level" => 12, "receive_low_stock_notification" => false)
      expect(audits("availability_update").sole.changes_json)
        .to eq("low_stock_level" => [ "10.0", "12.0" ], "receive_low_stock_notification" => [ true, false ])
    end

    it "reports no change without writing" do
      result = service.update(setting_id: row.id, low_stock_level: 10, reorder_quantity: 20, receive_low_stock_notification: true)
      expect(result.error).to eq(:unchanged)
      expect(audits("availability_update")).to be_empty
    end

    it "refuses an Inactive pair (reactivate first)" do
      service.deactivate(setting_id: row.id, reason: "seasonal")
      expect(service.update(setting_id: row.id, low_stock_level: 1, reorder_quantity: 1, receive_low_stock_notification: true).error)
        .to eq(:inactive)
    end

    it "refuses low-stock settings for an untracked product, but allows clearing them" do
      towel_row = ProductWarehouseSetting.create!(product: towel, warehouse: central) # pre-existing row (no new ones now)
      expect(service.update(setting_id: towel_row.id, low_stock_level: 1, reorder_quantity: 0, receive_low_stock_notification: true).error)
        .to eq(:untracked_product_settings)
    end
  end

  describe "#deactivate / #reactivate" do
    let!(:row) do
      service.add_many(warehouse_id: central.id, items: [ item(shampoo, low: 7, reorder: 14, notify: false) ])
      ProductWarehouseSetting.find_by!(product: shampoo, warehouse: central)
    end
    let!(:receipt) do
      r = business.goods_receipts.build(warehouse: central, received_on: Date.current)
      r.items.build(product: shampoo, quantity: 4, unit_cost: 5)
      Inventory::GoodsReceiptPoster.new(r).call.receipt
    end

    it "requires a reason" do
      expect(service.deactivate(setting_id: row.id, reason: "  ").error).to eq(:reason_required)
      expect(row.reload).to be_status_active
    end

    it "deactivates with the dependency summary, keeps settings and history, and audits the reason" do
      Inventory::PurchaseRequestCreator.new(business, actor: owner,
        items: [ { product_id: shampoo.id, quantity: 2, unit_price: 5, warehouse_id: central.id } ]).call
      draft = business.goods_receipts.build(warehouse: central, received_on: Date.current)
      draft.items.build(product: shampoo, quantity: 1, unit_cost: 5)
      draft.save!
      movements_before = InventoryMovement.where(product: shampoo).pluck(:id, :quantity, :direction)

      result = service.deactivate(setting_id: row.id, reason: "moved to Nasr City")

      expect(result).to be_ok
      expect(result.dependencies).to include(on_hand: "4.0", reserved: "0.0", open_purchase_request_lines: 1,
                                             draft_goods_receipt_lines: 1, open_stock_issue_lines: 0, open_stock_count_lines: 0)
      row.reload
      expect(row).to be_status_inactive
      expect([ row.status_reason, row.status_changed_by_id ]).to eq([ "moved to Nasr City", owner.id ])
      expect([ row.low_stock_level, row.reorder_quantity, row.receive_low_stock_notification ]).to eq([ 7, 14, false ])
      expect(InventoryMovement.where(product: shampoo).pluck(:id, :quantity, :direction)).to eq(movements_before)

      entry = audits("availability_deactivate").sole
      expect(entry.metadata).to include("reason" => "moved to Nasr City")
      expect(entry.metadata["dependencies"]).to include("on_hand" => "4.0", "open_purchase_request_lines" => 1)
    end

    it "reactivates with the kept settings, without re-entering them" do
      service.deactivate(setting_id: row.id, reason: "seasonal")
      result = service.reactivate(setting_id: row.id, reason: "season started")

      expect(result).to be_ok
      expect(row.reload).to be_status_active
      expect([ row.low_stock_level, row.reorder_quantity, row.receive_low_stock_notification ]).to eq([ 7, 14, false ])
      expect(audits("availability_reactivate").sole.metadata["kept_settings"]).to include("low_stock_level" => "7.0")
    end

    it "refuses repeated transitions and reactivation in an inactive warehouse" do
      expect(service.reactivate(setting_id: row.id).error).to eq(:already_active)
      service.deactivate(setting_id: row.id, reason: "x")
      expect(service.deactivate(setting_id: row.id, reason: "x").error).to eq(:already_inactive)
      central.update_column(:status, "inactive")
      expect(service.reactivate(setting_id: row.id).error).to eq(:inactive_warehouse)
    end

    it "keeps the pair Active when the audit entry cannot be written" do
      fail_audit_writes!(:availability_deactivate)
      expect(service.deactivate(setting_id: row.id, reason: "x").error).to eq(:audit_failed)
      expect(row.reload).to be_status_active
    end
  end
end
