require "rails_helper"

# Characterization (Pilot 6 — Inventory & Purchasing Supplier, M1) — CURRENT
# role of Supplier in purchasing: purchase requests own supplier selection,
# goods receipts reference (never write) the supplier, Supplier owns no
# purchasing behaviour, and the supplier reports stay inside the business and
# the requested warehouses. Complements spec/requests/inventory/purchase_requests_spec.rb
# (one request per supplier, missing supplier), purchase_request_goods_receipt_spec.rb
# (prefill from a request), reports_spec.rb (warehouse-scoped stock reports) and
# the SEC-P6-1/2/3 regression specs.
RSpec.describe "Characterization: Supplier in purchasing" do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:supplier)         { business.suppliers.create!(name: "Own Supplier") }
  let!(:second_supplier)  { business.suppliers.create!(name: "Second Supplier") }
  let!(:foreign_supplier) { other.suppliers.create!(name: "Foreign Supplier") }
  let!(:wh_a) { business.warehouses.create!(name: "WH A") }
  let!(:wh_b) { business.warehouses.create!(name: "WH B") }
  let(:product) { business.products.create!(name: "Dye", sku: "DY-1", initial_cost_price: 1, average_cost_price: 1) }
  let(:other_product) { business.products.create!(name: "Oil", sku: "OL-1", initial_cost_price: 1, average_cost_price: 1) }

  def request_for(supplier_record)
    business.purchase_requests.build(supplier: supplier_record,
                                     items_attributes: [ { product_id: product.id, quantity: 2, unit_price: 5 } ])
  end

  def post_receipt(warehouse, supplier_record, cost: 10, purchase_request: nil)
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier_record, received_on: Date.current,
                                      purchase_request: purchase_request)
    r.items.build(product: product, quantity: 1, unit_cost: cost)
    Inventory::GoodsReceiptPoster.new(r).call
    r.reload
  end

  describe "purchase requests own supplier selection" do
    it "a supplier is optional on a draft, but a dangling supplier id is refused" do
      expect(request_for(nil)).to be_valid

      dangling = request_for(nil).tap { |r| r.supplier_id = Supplier.maximum(:id).to_i + 1 }
      expect(dangling).not_to be_valid
      expect(dangling.errors[:supplier]).to be_present
    end

    it "the supplier must belong to the request's business" do
      request = request_for(foreign_supplier)
      expect(request).not_to be_valid
      expect(request.errors[:supplier]).to be_present
      expect(request_for(supplier)).to be_valid
    end

    it "the creator makes one request per supplier, and a no-supplier request for lines without one" do
      result = Inventory::PurchaseRequestCreator.new(
        business, actor: create(:user, :owner, business: business),
        items: [ { product_id: product.id, quantity: 1, unit_price: 1, supplier_id: supplier.id },
                 { product_id: other_product.id, quantity: 2, unit_price: 1, supplier_id: second_supplier.id } ]
      ).call
      expect(result).to be_ok
      expect(result.purchase_requests.map(&:supplier)).to contain_exactly(supplier, second_supplier)

      missing = Inventory::PurchaseRequestCreator.new(
        business, actor: create(:user, business: business),
        items: [ { product_id: product.id, quantity: 1, unit_price: 1, supplier_id: nil } ]
      ).call
      expect(missing).to be_ok
      expect(missing.purchase_requests.sole.supplier_id).to be_nil
    end

    it "the creator does not create a request for another business's supplier" do
      result = Inventory::PurchaseRequestCreator.new(
        business, actor: create(:user, :owner, business: business),
        items: [ { product_id: product.id, quantity: 1, unit_price: 1, supplier_id: foreign_supplier.id } ]
      ).call

      expect(result).not_to be_ok
      expect(PurchaseRequest.where(supplier: foreign_supplier)).to be_empty
    end

    it "the purchase-request policy decides without the supplier" do
      code = File.read(Rails.root.join("app/policies/purchase_request_policy.rb"))
      expect(code).not_to match(/supplier/i)
    end
  end

  describe "goods receipts reference the supplier" do
    it "the supplier is optional on a standalone receipt" do
      expect(post_receipt(wh_a, nil).supplier).to be_nil
    end

    it "a receipt from a request WITHOUT a supplier records its own actual supplier (or none)" do
      request = request_for(nil).tap(&:save!)

      [ supplier, second_supplier, nil ].each do |actual|
        receipt = business.goods_receipts.build(warehouse: wh_a, supplier: actual, received_on: Date.current,
                                                purchase_request: request)
        receipt.items.build(product: product, quantity: 1, unit_cost: 1)
        receipt.valid?
        expect(receipt.errors.details[:supplier]).to be_empty
      end
      expect(request.reload.supplier_id).to be_nil
    end

    it "a receipt from a purchase request must use that request's supplier" do
      request = request_for(supplier).tap(&:save!)
      receipt = business.goods_receipts.build(warehouse: wh_a, supplier: second_supplier, received_on: Date.current,
                                              purchase_request: request)
      receipt.items.build(product: product, quantity: 1, unit_cost: 1)

      expect(receipt).not_to be_valid
      expect(receipt.errors.details[:supplier]).to include(error: :must_match_purchase_request)

      receipt.supplier = supplier
      receipt.valid?
      expect(receipt.errors.details[:supplier]).to be_empty
    end

    it "posting and editing receipts never writes the supplier" do
      stamp = supplier.reload.updated_at
      receipt = post_receipt(wh_a, supplier)
      receipt.update!(notes: "edited")

      expect(supplier.reload.updated_at).to eq(stamp)
    end
  end

  describe "Supplier owns no purchasing behaviour" do
    it "has only business and goods_receipts associations, and no callbacks" do
      expect(Supplier.reflect_on_all_associations.map(&:name)).to contain_exactly(:business, :goods_receipts)
      expect(Supplier.reflect_on_association(:goods_receipts).options).to include(dependent: :restrict_with_error)

      code = File.read(Rails.root.join("app/models/inventory_purchasing/supplier.rb"))
      expect(code).not_to match(/\b(?:before|after|around)_\w+/)
      expect(code.scan(/^\s*def (\w+\??)/).flatten).to eq([ "map_location?" ])
    end
  end

  describe "supplier reports" do
    before do
      post_receipt(wh_a, supplier, cost: 10)
      post_receipt(wh_b, supplier, cost: 30)
      post_receipt(wh_b, second_supplier, cost: 7)
      foreign_wh = other.warehouses.create!(name: "Foreign WH")
      foreign_product = other.products.create!(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1)
      foreign = other.goods_receipts.build(warehouse: foreign_wh, supplier: foreign_supplier, received_on: Date.current)
      foreign.items.build(product: foreign_product, quantity: 1, unit_cost: 99)
      Inventory::GoodsReceiptPoster.new(foreign).call
    end

    def totals(report) = report.rows.to_h { |row| [ row.supplier, row.total_value ] }

    it "supplier purchases cover only the business's posted receipts, per supplier" do
      expect(totals(Inventory::Reports::SupplierPurchases.new(business))).to eq(supplier => 40, second_supplier => 7)
    end

    it "restricted to the requested warehouses" do
      expect(totals(Inventory::Reports::SupplierPurchases.new(business, warehouse_ids: [ wh_a.id ]))).to eq(supplier => 10)
    end

    it "a filter on another business's supplier returns nothing" do
      expect(Inventory::Reports::SupplierPurchases.new(business, supplier_id: foreign_supplier.id).rows).to be_empty
      expect(Inventory::Reports::Purchases.new(business, supplier_id: foreign_supplier.id).rows).to be_empty
    end

    it "the purchases report lists each receipt with its supplier, inside the business" do
      rows = Inventory::Reports::Purchases.new(business).rows
      expect(rows.map(&:supplier)).to contain_exactly(supplier, supplier, second_supplier)
    end

    it "the low-stock report shows each product's default supplier" do
      product.update!(default_supplier: second_supplier, reorder_level: 100)
      rows = Inventory::Reports::LowStock.new(business).rows

      expect(rows.map(&:supplier).uniq).to eq([ second_supplier ])
    end
  end
end
