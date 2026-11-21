require "rails_helper"

# Inventory::LegacyCentralSettingsBackfill: legacy product-wide
# low_stock_level / reorder_quantity -> the business's ONE central warehouse
# row. Preview (dry_run) writes nothing; apply! goes through
# ProductAvailabilityManager#add_many (authorized, audited), all or nothing,
# and only when this environment's preview still holds.
RSpec.describe Inventory::LegacyCentralSettingsBackfill do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Central", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City", kind: "branch", branch: create(:branch, business: business)) }
  let(:manager) { Inventory::ProductAvailabilityManager.new(actor: owner) }

  # ready: the product already has an availability row elsewhere (an Active
  # branch row at 0 / 0), so it no longer relies on the legacy total alert and
  # a central row cannot silently end one. ready: false = no row anywhere.
  def product(name, ready: true, **attrs)
    item = business.products.create!(name: name, sku: name.upcase.tr(" ", "-"), initial_cost_price: 1, average_cost_price: 1, **attrs)
    manager.save_settings(product_id: item.id, warehouse_id: branch_wh.id, low_stock_level: 0, reorder_quantity: 0) if ready
    item
  end

  def central_rows = ProductWarehouseSetting.where(warehouse: central)
  def transfer_logs = AuditLog.where(action: "availability_add").select { |log| log.metadata["source"] == described_class::SOURCE }

  def backfill = described_class.new(business, actor: owner)

  # Apply with the expectations a human copies from this environment's preview.
  def apply!
    preview = backfill.dry_run
    backfill.apply!(expected_central_id: preview.central&.id, expected_count: preview.to_create_count)
  end

  def stock!(item, warehouse, qty)
    InventoryMovement.create!(business: business, product: item, warehouse: warehouse, direction: :in, quantity: qty,
                              unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
  end

  it "maps low_stock_level and reorder_quantity exactly (zeros and decimals kept); reorder_level is never copied" do
    a = product("A", low_stock_level: 5, reorder_quantity: 12.5, reorder_level: 40, receive_low_stock_notification: false)
    b = product("B", low_stock_level: 3, reorder_quantity: 0)
    product("Z") # no legacy values: nothing to transfer (listed as an exception: it still has the legacy alert)

    preview = backfill.dry_run
    expect(preview.by_category).to eq("to_create" => 2, "legacy_alert_only" => 1)
    expect(preview.of("to_create").map(&:destination)).to eq(
      [ { low_stock_level: 5, reorder_quantity: 12.5, receive_low_stock_notification: false },
        { low_stock_level: 3, reorder_quantity: 0, receive_low_stock_notification: true } ]
    )
    expect(central_rows.count).to eq(0) # the preview writes nothing

    report = apply!
    expect(report).to have_attributes(applied: true, error: nil)
    expect(report.created.size).to eq(2)
    rows = central_rows.order(:product_id).map { |r| [ r.product_id, r.warehouse_id, r.status, r.low_stock_level, r.reorder_quantity, r.receive_low_stock_notification ] }
    expect(rows).to eq([ [ a.id, central.id, "active", 5, 12.5, false ], [ b.id, central.id, "active", 3, 0, true ] ])
    expect(ProductWarehouseSetting.where(low_stock_level: 40)).to be_empty
    expect([ a.reload.low_stock_level, a.reorder_level, b.reload.reorder_quantity ]).to eq([ 5, 40, 0 ]) # legacy columns untouched
  end

  it "records one audit entry per row with the actor and the transfer source" do
    a = product("A", low_stock_level: 5)
    apply!
    log = transfer_logs.sole
    expect(log).to have_attributes(actor_id: owner.id, auditable: central_rows.find_by!(product: a))
    expect(log.metadata).to include("source" => described_class::SOURCE, "warehouse_id" => central.id, "product_id" => a.id)
  end

  it "keeps a reorder-only product's exact reorder quantity with threshold 0 (no alert, nothing invented)" do
    p = product("Reorder only", low_stock_level: 0, reorder_quantity: 24)
    expect(backfill.dry_run.by_category).to eq("to_create" => 1)
    apply!
    expect(central_rows.sole).to have_attributes(product_id: p.id, low_stock_level: 0, reorder_quantity: 24)
    stock!(p, central, 0.001)
    expect(Inventory::LowStockQuery.new(business).alerts).to be_empty # threshold 0 = no low-stock alert
  end

  it "never overwrites an Active central row, never reactivates an Inactive one, and reports both" do
    same = product("Same", low_stock_level: 4, reorder_quantity: 8)
    diff = product("Diff", low_stock_level: 4, reorder_quantity: 8)
    off  = product("Off", low_stock_level: 2)
    manager.add_many(warehouse_id: central.id, items: [ { product_id: same.id, low_stock_level: 4, reorder_quantity: 8 },
                                                         { product_id: diff.id, low_stock_level: 9, reorder_quantity: 1 },
                                                         { product_id: off.id, low_stock_level: 7 } ])
    manager.deactivate(setting_id: central_rows.find_by!(product: off).id, reason: "historical")
    before = ProductWarehouseSetting.order(:id).pluck(:id, :status, :low_stock_level, :reorder_quantity)

    report = apply!
    expect(report.by_category).to eq("matching" => 1, "differing" => 1, "inactive_conflict" => 1)
    expect(report.of("differing").sole.setting.low_stock_level).to eq(9)
    expect(ProductWarehouseSetting.order(:id).pluck(:id, :status, :low_stock_level, :reorder_quantity)).to eq(before)
  end

  describe "the alert hand-over (legacy total alert -> central warehouse alert)" do
    def alerts = Inventory::LowStockQuery.new(business).alerts.map { |a| [ a.product.name, a.warehouse_id, a.low_stock_level ] }

    it "keeps the legacy total alert until the transfer, then the central alert replaces it — no gap, no duplicate" do
      p = product("P", ready: false, low_stock_level: 5, reorder_quantity: 10, reorder_level: 100)
      stock!(p, central, 4)
      row = backfill.dry_run.rows.sole
      expect(row).to have_attributes(category: "to_create", relies_on_total_alert: true)
      expect(row.alert_change).to eq(before: :total_level, after: :central)
      expect(alerts).to eq([ [ "P", nil, 100 ] ])            # before: the legacy total alert, as today

      expect(apply!.error).to be_nil
      expect(alerts).to eq([ [ "P", central.id, 5 ] ])       # after: only the central alert (exact threshold)
      expect(Inventory::LowStockQuery.new(business).alerts.sole.reorder_quantity).to eq(10)
      expect(p.reload.reorder_level).to eq(100)              # legacy columns untouched, never mapped
    end

    it "the central alert fires only where the central stock is low (warehouse-based from then on)" do
      p = product("P", ready: false, low_stock_level: 5, reorder_level: 100)
      stock!(p, central, 50)
      stock!(p, branch_wh, 1)
      expect(alerts).to eq([ [ "P", nil, 100 ] ]) # total 51 <= 100
      apply!
      expect(alerts).to be_empty                  # central 50 > 5: nothing to report
    end

    it "level 0: the out-of-stock total alert is kept until the transfer; a transferred threshold 0 means no alert (listed)" do
      p = product("Out of stock", ready: false, low_stock_level: 0, reorder_quantity: 3)
      expect(alerts).to eq([ [ "Out of stock", nil, 0 ] ])
      row = backfill.dry_run.rows.sole
      expect(row.alert_change).to eq(before: :out_of_stock, after: :none)
      expect(row).to be_loses_alert # stated in the preview before anything is applied
      apply!
      expect(central_rows.sole).to have_attributes(low_stock_level: 0, reorder_quantity: 3)
      expect(alerts).to be_empty
    end

    it "product 364's case: a branch row does not end the legacy alert; the transfer saves 2 / 6 as the real central settings" do
      p364 = product("364", ready: false, low_stock_level: 2, reorder_quantity: 6, reorder_level: 2)
      manager.save_settings(product_id: p364.id, warehouse_id: branch_wh.id, low_stock_level: 0, reorder_quantity: 0) # a user saved a branch card
      expect(alerts).to eq([ [ "364", nil, 2 ] ]) # its legacy total alert is still working
      expect(backfill.dry_run.rows.sole.alert_change).to eq(before: :total_level, after: :central)

      apply!
      expect(central_rows.sole).to have_attributes(product_id: p364.id, status: "active", low_stock_level: 2, reorder_quantity: 6)
      expect(ProductWarehouseSetting.find_by!(warehouse: branch_wh)).to have_attributes(low_stock_level: 0, reorder_quantity: 0) # never copied to branches
      expect(alerts).to eq([ [ "364", central.id, 2 ] ]) # the central alert replaced it (no stock yet: 0 <= 2)
    end

    it "a product with alerts off has nothing to hand over" do
      alerts_off = product("Alerts off", ready: false, low_stock_level: 3, reorder_level: 5, receive_low_stock_notification: false)
      expect(backfill.dry_run.rows.sole.alert_change).to eq(before: :none, after: :none)
      apply!
      expect(central_rows.pluck(:product_id)).to eq([ alerts_off.id ])
    end

    it "never two alerts for one product: a firing branch alert stands in for the legacy total alert" do
      p = product("P", ready: false, low_stock_level: 5, reorder_level: 100)
      manager.save_settings(product_id: p.id, warehouse_id: branch_wh.id, low_stock_level: 3, reorder_quantity: 1)
      expect(alerts).to eq([ [ "P", branch_wh.id, 3 ] ]) # branch at 0 <= 3: one alert, not also the total one
      stock!(p, branch_wh, 10)
      expect(alerts).to eq([ [ "P", nil, 100 ] ])        # branch fine, total 10 <= 100: the legacy alert again
    end

    it "lists a product with no legacy values that relies on the legacy alert as an exception: not transferred, alert kept" do
      only = product("Only alert", ready: false)
      expect(backfill.dry_run.by_category).to eq("legacy_alert_only" => 1)
      expect(backfill.dry_run.exceptions.map(&:product)).to eq([ only ])
      apply!
      expect(ProductWarehouseSetting.count).to eq(0)
      expect(alerts).to eq([ [ "Only alert", nil, 0 ] ])
    end

    it "a failed transfer leaves every product on its legacy alert (never without one)" do
      product("A", ready: false, low_stock_level: 5, reorder_level: 3)
      product("B", ready: false, low_stock_level: 6, reorder_level: 4)
      before = alerts
      allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_wrap_original do |original, *args, **kwargs|
        @calls = (@calls || 0) + 1
        raise AuditLoggable::AuditWriteFailed, "down" if @calls == 2

        original.call(*args, **kwargs)
      end
      expect(apply!.error).to eq(:audit_failed)
      expect(ProductWarehouseSetting.count).to eq(0)
      expect(alerts).to eq(before)
      expect(before.map(&:second)).to all(be_nil) # legacy total alerts
    end

    it "rolls back when a created row does not verify against the legacy values" do
      product("A", ready: false, low_stock_level: 5, reorder_level: 3)
      before = alerts
      allow_any_instance_of(described_class).to receive(:verified?).and_return(false)
      expect(apply!.error).to eq(:verification_failed)
      expect(ProductWarehouseSetting.count).to eq(0)
      expect(transfer_logs).to be_empty
      expect(alerts).to eq(before)
    end
  end

  it "does not transfer untracked or archived products (reported, values kept)" do
    chair = product("Chair", ready: false, low_stock_level: 2, track_inventory: false)
    old   = product("Old", ready: false, low_stock_level: 2, active: false)
    report = apply!
    expect(report.by_category).to eq("untracked" => 1, "archived" => 1)
    expect(ProductWarehouseSetting.count).to eq(0)
    expect([ chair.reload.low_stock_level, old.reload.low_stock_level ]).to eq([ 2, 2 ])
  end

  it "marks every product unresolved without a central warehouse, and refuses with several (never guesses)" do
    product("A", low_stock_level: 5)
    central.update!(status: "inactive")
    report = backfill.dry_run
    expect(report).to be_unresolved
    expect(report).not_to be_ambiguous
    expect(report.by_category).to eq("unresolved_central" => 1)
    expect(backfill.apply!(expected_central_id: central.id, expected_count: 1).error).to eq(:no_central)

    central.update!(status: "active")
    business.warehouses.create!(name: "Second Central", kind: "central")
    report = backfill.dry_run
    expect(report).to be_ambiguous
    expect(report.central_candidates.map(&:name)).to contain_exactly("Main Central", "Second Central")
    expect(backfill.apply!(expected_central_id: central.id, expected_count: 1).error).to eq(:ambiguous_central)
    expect(central_rows.count).to eq(0)
  end

  it "finds the central warehouse per business by type, never by id, and never crosses businesses" do
    other = create(:business)
    other_owner = create(:user, :owner, business: other)
    other_central = other.warehouses.create!(name: "Other Central", kind: "central")
    mine   = product("Mine", low_stock_level: 3)
    theirs = other.products.create!(name: "Theirs", sku: "T-1", initial_cost_price: 1, average_cost_price: 1, low_stock_level: 9,
                                    receive_low_stock_notification: false)

    apply!
    expect(described_class.new(other, actor: other_owner).apply!(expected_central_id: other_central.id, expected_count: 1).error).to be_nil
    expect(ProductWarehouseSetting.where(product: mine).pluck(:warehouse_id)).to contain_exactly(branch_wh.id, central.id)
    expect(ProductWarehouseSetting.where(product: theirs).sole.warehouse_id).to eq(other_central.id)
  end

  describe "safety of apply" do
    it "refuses when the expectations do not match this environment's preview (wrong id or count): nothing written" do
      product("A", low_stock_level: 5)
      expect(backfill.apply!(expected_central_id: central.id + 1000, expected_count: 1).error).to eq(:preview_mismatch)
      expect(backfill.apply!(expected_central_id: central.id, expected_count: 2).error).to eq(:preview_mismatch)
      expect(central_rows.count).to eq(0)
    end

    it "requires an actor allowed to manage the central warehouse" do
      product("A", low_stock_level: 5)
      expect(described_class.new(business).apply!(expected_central_id: central.id, expected_count: 1).error).to eq(:no_actor)
      outsider = create(:user, business: business)
      expect(described_class.new(business, actor: outsider).apply!(expected_central_id: central.id, expected_count: 1).error).to eq(:not_authorized)
      expect(central_rows.count).to eq(0)
    end

    it "is all or nothing when interrupted mid-batch (audit failure on the 2nd row), and a retry completes it" do
      product("A", low_stock_level: 5)
      product("B", low_stock_level: 6)
      calls = 0
      allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        raise AuditLoggable::AuditWriteFailed, "down" if calls == 2

        original.call(*args, **kwargs)
      end
      report = apply!
      expect(report.error).to eq(:audit_failed)
      expect(central_rows.count).to eq(0)
      expect(transfer_logs).to be_empty

      report = apply! # retry once the cause is fixed: only what is still missing
      expect(report.error).to be_nil
      expect(central_rows.count).to eq(2)
    end

    it "re-running creates no duplicate and changes nothing" do
      p = product("P", ready: false, low_stock_level: 6)
      manager.save_settings(product_id: p.id, warehouse_id: branch_wh.id, low_stock_level: 1, reorder_quantity: 0)
      apply!
      snapshot = ProductWarehouseSetting.order(:id).pluck(:id, :warehouse_id, :low_stock_level, :updated_at)
      report = apply!
      expect(report).to have_attributes(error: nil, created: [])
      expect(ProductWarehouseSetting.order(:id).pluck(:id, :warehouse_id, :low_stock_level, :updated_at)).to eq(snapshot)
      expect(report.by_category).to eq("matching" => 1)
    end

    it "refuses (nothing written) when a row appears between the preview and the apply" do
      a = product("A", low_stock_level: 5)
      product("B", low_stock_level: 6)
      preview = backfill.dry_run
      manager.save_settings(product_id: a.id, warehouse_id: central.id, low_stock_level: 1, reorder_quantity: 0)
      report = backfill.apply!(expected_central_id: preview.central.id, expected_count: preview.to_create_count)
      expect(report.error).to eq(:preview_mismatch)
      expect(central_rows.count).to eq(1) # only the user's own row
    end
  end

  it "after the transfer the reconciliation report shows completed and pending products, and the exceptions" do
    moved   = product("Moved", low_stock_level: 5, reorder_quantity: 2)
    later   = product("Later", ready: false, low_stock_level: 3, reorder_level: 8)
    archived = product("Archived", ready: false, low_stock_level: 1, active: false)
    preview = backfill.dry_run
    backfill.apply!(expected_central_id: central.id, expected_count: preview.to_create_count)
    later_new = product("New later", ready: false, low_stock_level: 4) # appears after the transfer: pending

    r = Inventory::Reports::AvailabilityReconciliation.new(business)
    legacy = r.legacy.rows.index_by(&:product)
    expect(legacy[moved]).to have_attributes(status: "matches", transfer: "matching")
    expect(legacy[later]).to have_attributes(transfer: "matching")
    expect(legacy[archived].transfer).to eq("archived")
    expect(legacy[later_new].transfer).to eq("to_create")
    expect(r.transfer_preview.by_category).to eq("matching" => 2, "archived" => 1, "to_create" => 1)
    expect(r.legacy.rows.first.product).to eq(later_new).or eq(archived) # not-yet-configured listed first
  end
end
