require "rails_helper"

# Product CSV import: "Low Stock Level" / "Reorder Quantity" become the
# CENTRAL warehouse's availability settings for each new product — never the
# deprecated product-level columns — through ProductAvailabilityManager
# (authorized, audited). Any refusal leaves nothing behind.
RSpec.describe Inventory::Imports::ProductImporter, "central warehouse settings" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Central", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City", kind: "branch", branch: create(:branch, business: business)) }

  HEADER = [ "Product Name", "SKU", "Initial Cost", "Current Stock", "Low Stock Level", "Reorder Quantity" ].freeze

  def csv(*rows)
    CSV.generate do |out|
      out << HEADER
      rows.each { |row| out << row }
    end
  end

  def import(data, user: owner, warehouse: nil) = described_class.new(business, data, warehouse: warehouse, user: user).call

  def central_rows = ProductWarehouseSetting.where(warehouse: central)

  it "writes the exact values (zeros and decimals kept) to the central warehouse, never to the product columns" do
    result = import(csv([ "Shampoo", "SH-1", "5", "", "2", "6" ],
                        [ "Mask", "MK-1", "5", "", "0", "12.5" ],
                        [ "Comb", "CB-1", "5", "", "0", "0" ],
                        [ "Brush", "BR-1", "5", "", "4", "" ]))
    expect(result).to be_ok
    expect(result.created_count).to eq(4)

    rows = central_rows.includes(:product).to_h { |r| [ r.product.sku, [ r.status, r.low_stock_level, r.reorder_quantity ] ] }
    expect(rows).to eq("SH-1" => [ "active", 2, 6 ], "MK-1" => [ "active", 0, 12.5 ], "CB-1" => [ "active", 0, 0 ], "BR-1" => [ "active", 4, 0 ])
    expect(business.products.pluck(:low_stock_level, :reorder_quantity).uniq).to eq([ [ 0, 0 ] ]) # deprecated columns untouched
    expect(ProductWarehouseSetting.where(warehouse: branch_wh)).to be_empty # never copied to branches
  end

  it "creates no central row when both cells are blank (or the columns are absent)" do
    expect(import(csv([ "Shampoo", "SH-1", "5", "", "", "" ]))).to be_ok
    expect(import("Product Name,SKU,Initial Cost\nMask,MK-1,5\n")).to be_ok
    expect(ProductWarehouseSetting.count).to eq(0)
    expect(business.products.count).to eq(2)
  end

  it "audits every central row with the importing user and source product_import" do
    import(csv([ "Shampoo", "SH-1", "5", "", "2", "6" ]))
    log = AuditLog.where(action: "availability_add").sole
    expect(log).to have_attributes(actor_id: owner.id, auditable: central_rows.sole)
    expect(log.metadata).to include("source" => "product_import", "warehouse_id" => central.id)
  end

  it "the central warehouse alert then works from the imported threshold" do
    import(csv([ "Shampoo", "SH-1", "5", "", "2", "6" ]))
    alert = Inventory::LowStockQuery.new(business).alerts.sole
    expect(alert).to have_attributes(warehouse_id: central.id, low_stock_level: 2, reorder_quantity: 6)
  end

  it "skips a row with a non-numeric or negative value, imports the rest" do
    result = import(csv([ "Shampoo", "SH-1", "5", "", "abc", "6" ], [ "Mask", "MK-1", "5", "", "-1", "0" ], [ "Comb", "CB-1", "5", "", "1", "1" ]))
    expect(result).to be_ok
    expect(result.skipped.map { |s| [ s.sku, s.reason ] }).to eq([ [ "SH-1", :invalid_stock_settings ], [ "MK-1", :invalid_stock_settings ] ])
    expect(central_rows.includes(:product).map { |r| r.product.sku }).to eq([ "CB-1" ])
  end

  describe "refusals: nothing is imported (no product, no row, no audit entry)" do
    def expect_nothing_written!
      expect(Product.where(business: business).count).to eq(0)
      expect(ProductWarehouseSetting.count).to eq(0)
      expect(AuditLog.where(action: "availability_add")).to be_empty
    end

    it "no active central warehouse" do
      central.update!(status: "inactive")
      result = import(csv([ "Shampoo", "SH-1", "5", "", "2", "6" ]))
      expect(result).not_to be_ok
      expect(result.settings_error).to eq(:no_central_warehouse)
      expect_nothing_written!
    end

    it "several active central warehouses (never guessed, never by id)" do
      business.warehouses.create!(name: "Second Central", kind: "central")
      result = import(csv([ "Shampoo", "SH-1", "5", "", "2", "6" ]))
      expect(result.settings_error).to eq(:ambiguous_central_warehouse)
      expect_nothing_written!
    end

    it "an importing user who may not manage the central warehouse" do
      clerk = create(:user, business: business)
      result = import(csv([ "Shampoo", "SH-1", "5", "", "2", "6" ]), user: clerk)
      expect(result.settings_error).to eq(:not_authorized)
      expect_nothing_written!
    end

    it "an audit entry that cannot be written (after some rows were created)" do
      calls = 0
      allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        raise AuditLoggable::AuditWriteFailed, "down" if calls == 2

        original.call(*args, **kwargs)
      end
      result = import(csv([ "Shampoo", "SH-1", "5", "", "2", "6" ], [ "Mask", "MK-1", "5", "", "1", "1" ]))
      expect(result.settings_error).to eq(:audit_failed)
      expect_nothing_written!
    end

    it "a conflicting existing central row is never overwritten" do
      allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:add_many).and_wrap_original do |original, **kwargs|
        # Another writer created the row between the product insert and the settings write.
        product_id = kwargs[:items].first[:product_id]
        ProductWarehouseSetting.create!(product_id: product_id, warehouse: central, low_stock_level: 9, reorder_quantity: 9)
        original.call(**kwargs)
      end
      result = import(csv([ "Shampoo", "SH-1", "5", "", "2", "6" ]))
      expect(result.settings_error).to eq(:settings_conflict)
      expect(Product.where(business: business).count).to eq(0)
      expect(ProductWarehouseSetting.where(low_stock_level: 2)).to be_empty
    end

    it "a refused opening balance also rolls back the central rows" do
      result = import(csv([ "Free Widget", "FW-1", "0", "5", "2", "6" ]), warehouse: central)
      expect(result.opening_errors).to be_present
      expect_nothing_written!
    end
  end
end
