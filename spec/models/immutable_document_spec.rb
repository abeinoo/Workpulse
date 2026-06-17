require "rails_helper"

RSpec.describe ImmutableDocument, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:warehouse_b) { business.warehouses.create!(name: "Branch") }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1",
                              initial_cost_price: 10, average_cost_price: 10)
  end

  # Build one posted document of each type, with stock already on hand.
  def posted_receipt
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call.receipt
  end

  def posted_issue
    posted_receipt
    i = business.stock_issues.build(warehouse: warehouse, branch: business.branches.first_or_create!(name: "Doc Branch", active: true), issued_on: Date.current)
    i.items.build(product: product, quantity: 2)
    Inventory::StockIssuePoster.new(i).call.issue
  end

  def posted_transfer
    posted_receipt
    t = business.stock_transfers.build(source_warehouse: warehouse,
                                       destination_warehouse: warehouse_b,
                                       transferred_on: Date.current)
    t.items.build(product: product, quantity: 3)
    Inventory::StockTransferPoster.new(t).call.transfer
  end

  shared_examples "an immutable document" do
    it "raises DeletionNotAllowedError on #destroy" do
      expect { document.destroy }.to raise_error(ImmutableDocument::DeletionNotAllowedError)
    end

    it "raises DeletionNotAllowedError on #destroy!" do
      expect { document.destroy! }.to raise_error(ImmutableDocument::DeletionNotAllowedError)
    end

    it "leaves the document, its items, and its movements intact after a blocked delete" do
      item_count     = document.items.count
      movement_count = document.inventory_movements.count
      expect(item_count).to be > 0
      expect(movement_count).to be > 0

      document.destroy rescue ImmutableDocument::DeletionNotAllowedError

      expect(document.class.exists?(document.id)).to be(true)
      expect(document.items.count).to eq(item_count)
      expect(document.inventory_movements.count).to eq(movement_count)
    end

    it "gives a clear, actionable error message" do
      expect { document.destroy }
        .to raise_error(ImmutableDocument::DeletionNotAllowedError, /immutable.*compensating document/im)
    end
  end

  describe GoodsReceipt do
    let(:document) { posted_receipt }
    it_behaves_like "an immutable document"
  end

  describe StockIssue do
    let(:document) { posted_issue }
    it_behaves_like "an immutable document"
  end

  describe StockTransfer do
    let(:document) { posted_transfer }
    it_behaves_like "an immutable document"
  end

  it "does not change stock when a delete is attempted and blocked" do
    receipt = posted_receipt
    expect(product.reload.current_stock).to eq(10)
    receipt.destroy rescue ImmutableDocument::DeletionNotAllowedError
    expect(product.reload.current_stock).to eq(10)
  end
end
