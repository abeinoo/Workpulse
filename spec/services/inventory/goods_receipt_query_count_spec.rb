require "rails_helper"

# Query cost of approving and confirming a Goods Receipt from a Purchase
# Request, by number of request lines:
#   - approval checks every line's approvable quantity in ONE grouped query
#     (PurchaseRequestItem.approvable_quantities) — constant from 3 to 30 lines;
#   - confirmation reads every line's remaining quantity and the request's
#     received total in grouped queries and preloads the products it posts —
#     what is left per line is the posting itself (stock read, movement insert,
#     the product's own cost-update validations).
RSpec.describe "Goods Receipt approval / confirmation query cost" do
  let(:business)  { create(:business) }
  let(:creator)   { create(:user, :super_admin, business: business) }
  let(:actor)     { create(:user, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }

  def request_with(lines, tag)
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: creator)
    lines.times { |i| pr.items.build(product: business.products.create!(name: "#{tag} #{i}", sku: "#{tag}-#{i}", average_cost_price: 5), quantity: 10, unit_price: 5, supplier: supplier) }
    pr.save!
    pr.update_column(:status, "approved")
    pr.reload
  end

  def receipt(pr, approval_status:)
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current, purchase_request: pr,
                                      created_by: creator, funding_source_kind: "supplier_credit")
    pr.items.each { |item| r.items.build(product: item.product, quantity: 1, unit_cost: 5, purchase_request_item: item) }
    r.save!
    r.update_column(:approval_status, approval_status)
    r
  end

  def queries(&block)
    log = []
    sub = ->(*, payload) { log << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(sub, "sql.active_record", &block)
    log
  end

  def approve(r) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: actor).approve!
  def confirm(r) = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: actor).call

  it "approval: the same number of queries for 3 and for 30 request lines" do
    small = receipt(request_with(3, "S"), approval_status: "pending_approval")
    large = receipt(request_with(30, "L"), approval_status: "pending_approval")
    approve(receipt(request_with(2, "W"), approval_status: "pending_approval")) # warm

    small_count = queries { expect(approve(small)).to be_ok }.size
    large_count = queries { expect(approve(large)).to be_ok }.size

    expect(large_count).to eq(small_count)
  end

  it "confirmation: grouped quantity reads, preloaded products — only the posting itself grows per line" do
    small = receipt(request_with(3, "S"), approval_status: "approved")
    large = receipt(request_with(30, "L"), approval_status: "approved")
    confirm(receipt(request_with(2, "W"), approval_status: "approved")) # warm

    small_log = queries { expect(confirm(small)).to be_ok }
    large_log = queries { expect(confirm(large)).to be_ok }

    per_line = (large_log.size - small_log.size) / 27.0
    expect(per_line).to be <= 5 # was ~10: stock read, insert, product update + its 2 validation reads
    # Never per line any more: received-quantity sums, product / barcode / image loads.
    per_line_reads = /FROM "goods_receipt_items"|FROM "products" WHERE "products"."id" =|FROM "product_barcodes"|FROM "active_storage_attachments"/
    expect(large_log.grep(per_line_reads).size).to eq(small_log.grep(per_line_reads).size)
  end

  it "posting two lines of the same product keeps the moving average sequential" do
    product = business.products.create!(name: "Soap", sku: "SO-1", average_cost_price: 0)
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: creator)
    pr.items.build(product: product, quantity: 20, unit_price: 100, supplier: supplier)
    pr.save!
    pr.update_column(:status, "approved")
    line = pr.items.sole

    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current, purchase_request: pr,
                                      created_by: creator, funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 10, unit_cost: 100, purchase_request_item: line)
    r.items.build(product: product, quantity: 10, unit_cost: 120, purchase_request_item: line)
    r.save!
    r.update_column(:approval_status, "approved")

    expect(confirm(r)).to be_ok
    expect(product.reload).to have_attributes(average_cost_price: 110, last_purchase_price: 120) # (10×100 + 10×120) / 20
    expect(product.current_stock).to eq(20)
  end
end
