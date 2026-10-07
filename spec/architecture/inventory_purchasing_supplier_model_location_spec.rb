require "rails_helper"

# Pilot 6 — Inventory & Purchasing Supplier (M7): Supplier lives physically in
# Inventory & Purchasing (app/models/inventory_purchasing/, the collapsed
# directory from config/initializers/inventory_purchasing_autoload.rb) but
# keeps its top-level constant, table and associations. Guards against an
# accidental un-collapse, namespace, table or association change.
RSpec.describe "Architecture: Inventory & Purchasing supplier model location" do
  it "loads Supplier as a top-level constant from app/models/inventory_purchasing/" do
    expect(Supplier.name).to eq("Supplier") # resolving the constant also triggers the autoload
    path = Object.const_source_location("Supplier").first
    expect(path).to eq(Rails.root.join("app/models/inventory_purchasing/supplier.rb").to_s)
  end

  it "no longer has a top-level model file" do
    expect(File).not_to exist(Rails.root.join("app/models/supplier.rb"))
  end

  it "keeps suppliers as its table" do
    expect(Supplier.table_name).to eq("suppliers")
  end

  it "is not namespaced under InventoryPurchasing, and leaves the Inventory:: namespace alone" do
    expect(defined?(::InventoryPurchasing)).to be_nil.or(satisfy { !::InventoryPurchasing.const_defined?(:Supplier, false) })
    expect(Inventory::SuppliersController.name).to eq("Inventory::SuppliersController")
    expect(Inventory.const_defined?(:Supplier, false)).to be(false)
  end

  it "resolves the same classes from every association" do
    expect(Supplier.reflect_on_association(:business).klass).to equal(Business)
    expect(Supplier.reflect_on_association(:goods_receipts).klass).to equal(GoodsReceipt)
    expect(Business.reflect_on_association(:suppliers).klass).to equal(Supplier)
    expect(Product.reflect_on_association(:default_supplier).klass).to equal(Supplier)
    expect(PurchaseRequest.reflect_on_association(:supplier).klass).to equal(Supplier)
    expect(GoodsReceipt.reflect_on_association(:supplier).klass).to equal(Supplier)
  end

  it "keeps its behaviour: business scoping, validations and the restrict on receipts" do
    business = create(:business)
    supplier = business.suppliers.create!(name: "Acme", latitude: 24.7, longitude: 46.7)

    expect(Supplier.for_business(business)).to contain_exactly(supplier)
    expect(supplier.map_location?).to be(true)
    expect(Supplier.new(business: business, name: "")).not_to be_valid
    expect(Supplier.reflect_on_association(:goods_receipts).options).to include(dependent: :restrict_with_error)
  end
end
