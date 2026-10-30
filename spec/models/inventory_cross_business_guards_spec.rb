require "rails_helper"

# IP-1: model-level guards behind the request spec
# (spec/requests/security/inventory_cross_business_references_spec.rb). These
# cover callers with no controller in front — console, jobs, services — and the
# InventoryMovement backstop every posting path writes through.
RSpec.describe "Inventory cross-business guards (IP-1)" do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  let(:own_warehouse)     { business.warehouses.create!(name: "Own A") }
  let(:own_warehouse_2)   { business.warehouses.create!(name: "Own B") }
  let(:foreign_warehouse) { other.warehouses.create!(name: "Foreign") }
  let(:own_product)       { business.products.create!(name: "Own", sku: "OWN-G", initial_cost_price: 1, average_cost_price: 1) }
  let(:foreign_product)   { other.products.create!(name: "Foreign", sku: "FOR-G", initial_cost_price: 1, average_cost_price: 1) }

  def other_business_errors(record)
    record.validate
    record.errors.select { |error| error.type == :other_business }.map(&:attribute)
  end

  describe StockTransfer do
    def transfer(source:, destination:, product:)
      business.stock_transfers.build(source_warehouse: source, destination_warehouse: destination,
                                     transferred_on: Date.current).tap do |t|
        t.items.build(product: product, quantity: 1)
      end
    end

    it "accepts warehouses and products of its own business" do
      expect(other_business_errors(transfer(source: own_warehouse, destination: own_warehouse_2, product: own_product))).to be_empty
    end

    it "refuses another business's source or destination warehouse" do
      expect(other_business_errors(transfer(source: foreign_warehouse, destination: own_warehouse, product: own_product)))
        .to contain_exactly(:source_warehouse_id)
      expect(other_business_errors(transfer(source: own_warehouse, destination: foreign_warehouse, product: own_product)))
        .to contain_exactly(:destination_warehouse_id)
    end

    it "refuses another business's product on a line" do
      expect(other_business_errors(transfer(source: own_warehouse, destination: own_warehouse_2, product: foreign_product)))
        .to contain_exactly(:"items.product_id")
    end
  end

  describe StockAdjustment do
    def adjustment(warehouse:, product:)
      business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current, reason: "damaged").tap do |a|
        a.items.build(product: product, quantity_difference: 1)
      end
    end

    it "accepts its own warehouse and product" do
      expect(other_business_errors(adjustment(warehouse: own_warehouse, product: own_product))).to be_empty
    end

    it "refuses another business's warehouse or product" do
      expect(other_business_errors(adjustment(warehouse: foreign_warehouse, product: own_product))).to contain_exactly(:warehouse_id)
      expect(other_business_errors(adjustment(warehouse: own_warehouse, product: foreign_product))).to contain_exactly(:"items.product_id")
    end
  end

  describe StockCount do
    def count(warehouse:, product:)
      business.stock_counts.build(warehouse: warehouse, counted_on: Date.current).tap do |c|
        c.items.build(product: product, system_quantity: 0)
      end
    end

    it "accepts its own warehouse and product" do
      expect(other_business_errors(count(warehouse: own_warehouse, product: own_product))).to be_empty
    end

    it "refuses another business's warehouse or product" do
      expect(other_business_errors(count(warehouse: foreign_warehouse, product: own_product))).to contain_exactly(:warehouse_id)
      expect(other_business_errors(count(warehouse: own_warehouse, product: foreign_product))).to contain_exactly(:"items.product_id")
    end
  end

  describe GoodsReceipt do
    def receipt(warehouse:, product:)
      business.goods_receipts.build(warehouse: warehouse, received_on: Date.current).tap do |r|
        r.items.build(product: product, quantity: 1, unit_cost: 1)
      end
    end

    it "accepts its own warehouse and product" do
      expect(other_business_errors(receipt(warehouse: own_warehouse, product: own_product))).to be_empty
    end

    it "refuses another business's warehouse or product" do
      expect(other_business_errors(receipt(warehouse: foreign_warehouse, product: own_product))).to contain_exactly(:warehouse_id)
      expect(other_business_errors(receipt(warehouse: own_warehouse, product: foreign_product))).to contain_exactly(:"items.product_id")
    end

    it "is refused by the poster, writing no movement" do
      expect {
        expect(Inventory::GoodsReceiptPoster.new(receipt(warehouse: foreign_warehouse, product: own_product)).call.ok?).to be(false)
      }.not_to change(InventoryMovement, :count)
    end

    # A draft written before the guards existed (simulated by bypassing
    # validation) is not re-checked on save — the warehouse did not change — so
    # only the InventoryMovement backstop stands between it and the other ledger.
    it "cannot post a pre-existing draft that names another business's warehouse" do
      draft = receipt(warehouse: own_warehouse, product: own_product)
      draft.receipt_number = "GR-LEGACY-1"
      draft.save!
      draft.update_column(:warehouse_id, foreign_warehouse.id)

      expect { Inventory::GoodsReceiptPoster.new(draft.reload).call }.to raise_error(ActiveRecord::RecordInvalid)
      expect(InventoryMovement.where(warehouse_id: foreign_warehouse.id)).to be_empty
      expect(draft.reload).to be_draft
    end
  end

  describe StockIssue do
    it "refuses another business's warehouse" do
      issue = business.stock_issues.build(warehouse: foreign_warehouse, branch: create(:branch, business: business),
                                          issued_on: Date.current)
      expect(other_business_errors(issue)).to contain_exactly(:warehouse_id)
    end
  end

  describe PurchaseRequestItem do
    it "refuses another business's source warehouse" do
      request = business.purchase_requests.build
      item    = request.items.build(product: own_product, quantity: 1, unit_price: 1, source_warehouse: foreign_warehouse)
      expect(other_business_errors(item)).to contain_exactly(:source_warehouse_id)

      item.source_warehouse = own_warehouse
      expect(other_business_errors(item)).to be_empty
    end
  end

  describe InventoryMovement do
    def movement(product:, warehouse:)
      InventoryMovement.new(business: business, product: product, warehouse: warehouse, direction: :in,
                            reason: :adjustment, quantity: 1, unit_cost: 1, occurred_on: Date.current)
    end

    it "accepts its own product and warehouse" do
      expect(other_business_errors(movement(product: own_product, warehouse: own_warehouse))).to be_empty
    end

    it "refuses a row naming another business's product or warehouse" do
      expect(other_business_errors(movement(product: foreign_product, warehouse: own_warehouse))).to contain_exactly(:product_id)
      expect(other_business_errors(movement(product: own_product, warehouse: foreign_warehouse))).to contain_exactly(:warehouse_id)
      expect { movement(product: own_product, warehouse: foreign_warehouse).save! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
