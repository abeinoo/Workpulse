require "rails_helper"

# docs/inventory/legacy_central_settings_console.rb — the Rails console script
# for moving legacy product-wide low-stock level / reorder quantity into the
# Central warehouse settings. The real file is run here (only its CONFIG block
# is replaced). Non-transactional, so its READ ONLY preview transaction and its
# APPLY transaction are real ones, as in a console.
RSpec.describe "docs/inventory/legacy_central_settings_console.rb" do
  include_context "non-transactional database"

  SCRIPT_PATH = Rails.root.join("docs/inventory/legacy_central_settings_console.rb")

  let!(:business)  { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let!(:central)   { business.warehouses.create!(name: "Main Central", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City", kind: "branch", branch: create(:branch, business: business)) }
  let(:manager)    { Inventory::ProductAvailabilityManager.new(actor: owner) }

  def product(name, **attrs)
    business.products.create!(name: name, sku: name.upcase.tr(" ", "-"), initial_cost_price: 1, average_cost_price: 1, **attrs)
  end

  # Runs the script file exactly as pasted into a console, with this config.
  def run_script(**config)
    config = { business_id: business.id, apply: false, actor_id: nil, expect_central_id: nil, expect_count: nil }.merge(config)
    source = SCRIPT_PATH.read
    script = source.sub(/^legacy_transfer_config = \{\n.*?^\}\n/m, "legacy_transfer_config = #{config.inspect}\n")
    raise "CONFIG block not found" if script == source

    output = StringIO.new
    original = $stdout
    $stdout = output
    result = begin
      eval(script, Object.new.instance_eval { binding }, SCRIPT_PATH.to_s) # rubocop:disable Security/Eval
    ensure
      $stdout = original
    end
    [ result, output.string ]
  end

  def snapshot = ProductWarehouseSetting.order(:id).map { |s| s.attributes.except("updated_at") }
  def transfer_audits = AuditLog.where(action: "availability_add").select { |log| log.metadata["source"] == "legacy_central_backfill" }

  # Eligible: no central row (a branch row does not count).
  let!(:shampoo) { product("Shampoo", low_stock_level: 5, reorder_quantity: 12.5, receive_low_stock_notification: false) }
  let!(:zero)    { product("Zero Low", low_stock_level: 0, reorder_quantity: 6) }
  let!(:mask)    { product("Mask", low_stock_level: 2, reorder_quantity: 0, reorder_level: 9) }
  # Skipped.
  let!(:same)     { product("Same", low_stock_level: 4, reorder_quantity: 8) }
  let!(:diff)     { product("Diff", low_stock_level: 4, reorder_quantity: 8) }
  let!(:off)      { product("Off", low_stock_level: 2) }
  let!(:archived) { product("Archived", low_stock_level: 1, active: false) }
  let!(:chair)    { product("Chair", low_stock_level: 2, track_inventory: false) }

  before do
    manager.save_settings(product_id: shampoo.id, warehouse_id: branch_wh.id, low_stock_level: 3, reorder_quantity: 4)
    manager.add_many(warehouse_id: central.id, items: [ { product_id: same.id, low_stock_level: 4, reorder_quantity: 8 },
                                                         { product_id: diff.id, low_stock_level: 9, reorder_quantity: 1 },
                                                         { product_id: off.id, low_stock_level: 7 } ])
    manager.deactivate(setting_id: ProductWarehouseSetting.find_by!(warehouse: central, product: off).id, reason: "historical")
  end

  describe "PREVIEW (default)" do
    it "reports the business, central warehouse, eligible products with values and status, skips with reasons — and writes nothing" do
      before_rows = snapshot
      audit_count = AuditLog.count
      result, out = run_script

      expect(result).to eq(:preview)
      expect(out).to include("[PREVIEW — READ ONLY — nothing written]", "Business: ##{business.id} #{business.name}",
                             "Central warehouse: ##{central.id} Main Central", "Eligible products: 3", "Would create: 3 central setting(s)",
                             "expect_central_id: #{central.id}, expect_count: 3", "Skipped products: 5")
      expect(out).to match(/product ##{shampoo.id}\s+Shampoo .*legacy low=5\.0 reorder=12\.5 \| central setting: Missing -> create low=5\.0 reorder=12\.5 notify=false/)
      expect(out).to match(/product ##{zero.id}\s+Zero Low .*legacy low=0\.0 reorder=6\.0 \| central setting: Missing -> create low=0\.0 reorder=6\.0/)
      expect(out).to match(/product ##{mask.id}\s+Mask .*-> create low=2\.0 reorder=0\.0/)
      expect(out).to match(/product ##{same.id}\s+Same .*central setting: Active \(row #\d+ low=4\.0 reorder=8\.0\) \| SKIPPED: Central setting already Active with the same values/)
      expect(out).to match(/product ##{diff.id}\s+Diff .*central setting: Active \(row #\d+ low=9\.0 reorder=1\.0\) \| SKIPPED: .*never overwritten/)
      expect(out).to match(/product ##{off.id}\s+Off .*central setting: Inactive .*SKIPPED: Central setting is Inactive — never reactivated or overwritten/)
      expect(out).to match(/product ##{archived.id}\s+Archived .*SKIPPED: Product is archived/)
      expect(out).to match(/product ##{chair.id}\s+Chair .*SKIPPED: Stock tracking is disabled/)

      expect(snapshot).to eq(before_rows)
      expect(AuditLog.count).to eq(audit_count)
    end

    it "runs in a READ ONLY transaction: a write attempted during the preview is rejected by PostgreSQL" do
      allow_any_instance_of(Inventory::LegacyCentralSettingsBackfill).to receive(:dry_run).and_wrap_original do |original|
        ProductWarehouseSetting.connection.execute("UPDATE products SET name = name")
        original.call
      end
      expect { run_script }.to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
    end

    it "shows an unresolved central warehouse (none, or several) and lists nothing to create" do
      central.update!(status: "inactive")
      _, out = run_script
      expect(out).to include("Central warehouse: NONE", "Eligible products: 0", "Would create: 0")
      expect(out).to match(/product ##{shampoo.id}\s+Shampoo .*SKIPPED: Business has no single active Central Warehouse/)

      central.update!(status: "active")
      second = business.warehouses.create!(name: "Second Central", kind: "central")
      _, out = run_script
      expect(out).to include("AMBIGUOUS — several active central warehouses #{[ central.id, second.id ]}", "Eligible products: 0")
    end

    it "stops on an unknown business" do
      result, out = run_script(business_id: 0)
      expect(result).to eq(:stopped)
      expect(out).to include("[STOPPED] business_id 0 not found")
    end
  end

  describe "APPLY" do
    def apply(**overrides)
      run_script(apply: true, actor_id: owner.id, expect_central_id: central.id, expect_count: 3, **overrides)
    end

    it "creates exactly the eligible central settings with the exact legacy values, audited; existing central and branch rows untouched" do
      before_rows = snapshot
      legacy_before = Product.order(:id).pluck(:id, :low_stock_level, :reorder_quantity, :reorder_level)
      result, out = apply

      expect(result).to eq(:applied)
      expect(out).to include("[APPLIED] created 3 central setting(s) as user ##{owner.id}", "Audit entries written: 3", "Skipped products: 5")
      created = ProductWarehouseSetting.where.not(id: before_rows.map { |r| r["id"] })
      expect(created.order(:product_id).pluck(:product_id, :warehouse_id, :status, :low_stock_level, :reorder_quantity, :receive_low_stock_notification))
        .to eq([ [ shampoo.id, central.id, "active", 5, 12.5, false ],
                 [ zero.id, central.id, "active", 0, 6, true ],
                 [ mask.id, central.id, "active", 2, 0, true ] ]) # reorder_level 9 never used
      expect(created.map(&:created_by_id).uniq).to eq([ owner.id ])
      expect(transfer_audits.map(&:auditable_id)).to match_array(created.ids)
      expect(transfer_audits.map(&:actor_id).uniq).to eq([ owner.id ])

      # Every row that existed before — the Active central rows (same / different
      # values), the Inactive central row and the branch row — is unchanged.
      expect(snapshot.select { |r| before_rows.map { |b| b["id"] }.include?(r["id"]) }).to eq(before_rows)
      expect(ProductWarehouseSetting.where(warehouse: branch_wh).count).to eq(1)
      expect(Product.order(:id).pluck(:id, :low_stock_level, :reorder_quantity, :reorder_level)).to eq(legacy_before)

      # A second run creates nothing: everything eligible is now an Active central row.
      _, again = run_script
      expect(again).to include("Eligible products: 0", "Would create: 0")
    end

    it "is refused without the confirmation values, with another environment's numbers, or with an outside actor — nothing written" do
      before_rows = snapshot
      expect(run_script(apply: true).last).to include("[APPLY REFUSED] missing actor_id, expect_central_id, expect_count")
      expect(apply(expect_count: 2).last).to include("[APPLY REFUSED: preview_mismatch] the whole operation was rolled back")
      expect(apply(expect_central_id: central.id + 999).last).to include("[APPLY REFUSED: preview_mismatch]")
      outsider = create(:user, :owner, business: create(:business))
      expect(apply(actor_id: outsider.id).last).to include("is not a user of business ##{business.id}")
      expect(run_script(apply: "yes").first).to eq(:preview) # only exactly true applies
      expect(snapshot).to eq(before_rows)
      expect(transfer_audits).to be_empty
    end

    it "is refused when the actor may not manage product availability" do
      clerk = create(:user, business: business)
      result, out = apply(actor_id: clerk.id)
      expect(result).to eq(:refused)
      expect(out).to include("[APPLY REFUSED: not_authorized]")
      expect(ProductWarehouseSetting.where(warehouse: central).count).to eq(3)
    end

    it "is refused with no single active central warehouse" do
      business.warehouses.create!(name: "Second Central", kind: "central")
      expect(apply.last).to include("[APPLY REFUSED: ambiguous_central]")
      central.update!(status: "inactive")
      Warehouse.where(business: business, name: "Second Central").update_all(status: "inactive")
      expect(apply.last).to include("[APPLY REFUSED: no_central]")
      expect(transfer_audits).to be_empty
    end

    it "rolls back everything when one row fails (audit failure on the 2nd row)" do
      before_rows = snapshot
      calls = 0
      allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        raise AuditLoggable::AuditWriteFailed, "down" if calls == 2

        original.call(*args, **kwargs)
      end
      result, out = apply
      expect(result).to eq(:refused)
      expect(out).to include("[APPLY REFUSED: audit_failed] the whole operation was rolled back")
      expect(snapshot).to eq(before_rows)
      expect(transfer_audits).to be_empty
    end

    it "is refused inside an open transaction (sandbox console), where the result would be rolled back" do
      result = nil
      ActiveRecord::Base.transaction do
        result, out = apply
        expect(out).to include("[APPLY REFUSED] a transaction is already open")
        raise ActiveRecord::Rollback
      end
      expect(result).to eq(:refused)
    end
  end
end
