require "rails_helper"

# When the import's opening-balance adjustment is refused, the importer used
# to return nil (its transaction block ended in ActiveRecord::Rollback), so
# the import page raised NoMethodError (500) and the reason was lost. It now
# rolls the whole import back and returns the refusal messages.
RSpec.describe Inventory::Imports::ProductImporter, "opening balance refusals" do
  let(:business)  { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Nasr City WH", kind: "central") }

  def import(csv) = described_class.new(business, csv, warehouse: warehouse, user: owner).call

  it "returns the refusal (product and reason) and imports nothing when a row has stock but no unit cost" do
    csv = "Product Name,SKU,Initial Cost,Current Stock\nGood Widget,GW-1,5,3\nFree Widget,FW-1,0,5\n"

    result = nil
    expect { result = import(csv) }.not_to change { [ Product.count, StockAdjustment.count, InventoryMovement.count ] }

    expect(result).not_to be_ok
    expect(result.opening_errors).to eq([ "Opening balance for Free Widget requires a unit cost" ])
    expect(result.created).to be_empty
  end

  it "still imports a valid file with its opening stock" do
    result = import("Product Name,SKU,Initial Cost,Current Stock\nGood Widget,GW-1,5,3\n")
    expect(result).to be_ok
    expect(result.opening_errors).to be_nil
    expect(business.products.find_by!(sku: "GW-1").stock_in(warehouse)).to eq(3)
  end

  # The importer only CREATES products (an existing SKU is skipped), and a new
  # product has no availability row — so its opening stock can never meet an
  # Inactive pair. An existing product that is Inactive there is skipped and
  # gets no stock.
  it "skips an existing product that is Inactive in the warehouse — no opening stock reaches the pair" do
    product = business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5)
    manager = Inventory::ProductAvailabilityManager.new(actor: owner)
    manager.add_many(warehouse_id: warehouse.id, items: [ { product_id: product.id } ])
    manager.deactivate(setting_id: ProductWarehouseSetting.find_by!(product: product).id, reason: "not sold here")

    result = import("Product Name,SKU,Initial Cost,Current Stock\nShampoo,SH-1,5,10\n")

    expect(result).to be_ok
    expect(result.skipped.map(&:reason)).to eq([ :duplicate_sku ])
    expect(product.reload.stock_in(warehouse)).to eq(0)
    expect(ProductWarehouseSetting.find_by!(product: product)).to be_status_inactive
  end
end
