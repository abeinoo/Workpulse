require "rails_helper"

# Smart replenishment for stock transfers (decisions D6–D8): destination
# position = on hand − reserved + incoming; eligible at or below the
# low-stock level; suggested = reorder quantity, else the deficit (min 1);
# capped at the source's available; a product the source cannot supply is
# listed and flagged, never omitted. LowStockQuery is not involved.
RSpec.describe Inventory::TransferReplenishment do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:source)  { business.warehouses.create!(name: "Main", kind: "central") }
  let!(:dest)    { business.warehouses.create!(name: "Annex") }
  let!(:other)   { business.warehouses.create!(name: "Other") }

  def product(name) = business.products.create!(name: name, sku: name.upcase, initial_cost_price: 1, average_cost_price: 1)

  def stock(item, warehouse, qty)
    InventoryMovement.create!(business: business, product: item, warehouse: warehouse, direction: :in, reason: :opening_balance,
                              quantity: qty, unit_cost: 1, occurred_on: Date.new(2026, 1, 1))
  end

  def setting(item, low:, reorder: 0, status: "active", warehouse: dest)
    attrs = { product: item, warehouse: warehouse, business: business, low_stock_level: low, reorder_quantity: reorder, status: status }
    attrs.merge!(status_reason: "x", status_changed_at: Time.current) if status == "inactive"
    ProductWarehouseSetting.create!(attrs)
  end

  def suggestions = described_class.new(business: business, source_warehouse_id: source.id, destination_warehouse_id: dest.id).suggestions
  def for_product(item) = suggestions.find { |s| s.product == item }

  it "suggests the reorder quantity for a product at or below its level, capped at the source's available" do
    shampoo = product("shampoo")
    setting(shampoo, low: 10, reorder: 50)
    stock(shampoo, dest, 4)
    stock(shampoo, source, 30)
    row = for_product(shampoo)
    expect([ row.on_hand, row.position, row.suggested, row.proposed, row.status ]).to eq([ 4, 4, 50, 30, :partial ])
  end

  it "suggests the deficit to the low-stock level when there is no reorder quantity (minimum 1)" do
    soap = product("soap")
    setting(soap, low: 10)
    stock(soap, dest, 3)
    stock(soap, source, 100)
    expect(for_product(soap).suggested).to eq(7)

    gel = product("gel")
    setting(gel, low: 5)
    stock(gel, dest, 5) # exactly at the level: eligible, deficit 0 -> minimum 1
    stock(gel, source, 100)
    expect(for_product(gel).suggested).to eq(1)
  end

  it "counts reservations and incoming stock, so nothing already on its way is requested again" do
    towel = product("towel")
    setting(towel, low: 10, reorder: 20)
    stock(towel, dest, 12)
    stock(towel, source, 100)
    stock(towel, other, 50)
    # 5 reserved at the destination by an approved stock issue -> position 7 (eligible)
    issue = business.stock_issues.build(warehouse: dest, issued_on: Date.current)
    issue.items.build(product: towel, quantity: 5)
    save_stock_issue_in_status!(issue, :approved)
    expect(for_product(towel).position).to eq(7)

    # a pending transfer of 6 toward the destination counts as incoming -> position 13 (not eligible)
    inbound = business.stock_transfers.build(source_warehouse: other, destination_warehouse: dest)
    inbound.items.build(product: towel, quantity: 6)
    save_stock_transfer_in_status!(inbound, :pending_approval)
    expect(for_product(towel)).to be_nil
    expect(Inventory::TransferIncoming.by_product(business_id: business.id, warehouse_id: dest.id, product_ids: [ towel.id ]))
      .to eq(towel.id => 6)
  end

  it "counts only what is still in transit for a dispatched transfer (never twice)" do
    cup = product("cup")
    stock(cup, other, 20)
    approver = user_with_stock_permissions(business, :view_stock_transfers, :create_stock_transfers, :approve_stock_transfers,
                                           :dispatch_stock_transfers, :receive_stock_transfers)
    t = Inventory::StockTransferDraftService.new(actor: approver, attributes: {
      source_warehouse_id: other.id, destination_warehouse_id: dest.id, items_attributes: { "0" => { product_id: cup.id, quantity: 10 } }
    }).call.transfer
    Inventory::StockTransferSubmission.new(stock_transfer_id: t.id, actor: approver).call
    Inventory::StockTransferApproval.new(stock_transfer_id: t.id, actor: approver).call
    Inventory::StockTransferDispatch.new(stock_transfer_id: t.id, actor: approver).call
    Inventory::StockTransferReceiving.new(stock_transfer_id: t.id, actor: approver, quantities: { t.items.first.id => 4 }).call
    expect(Inventory::TransferIncoming.by_product(business_id: business.id, warehouse_id: dest.id, product_ids: [ cup.id ]))
      .to eq(cup.id => 6)
  end

  it "lists a product the source cannot supply, flagged and not selectable (D8)" do
    rare = product("rare")
    setting(rare, low: 5, reorder: 10)
    row = for_product(rare)
    expect(row.status).to eq(:unavailable)
    expect(row).not_to be_selectable
    expect(row.proposed).to eq(0)
    expect(suggestions.last).to eq(row) # unavailable rows after the selectable ones
  end

  it "ignores inactive or zero-threshold settings, archived products and products above the level" do
    a = product("a")
    setting(a, low: 0)
    b = product("b")
    setting(b, low: 5, status: "inactive")
    c = product("c")
    setting(c, low: 5)
    c.update!(active: false)
    d = product("d")
    setting(d, low: 5)
    stock(d, dest, 6)
    expect(suggestions).to be_empty
  end

  it "does not change the existing low-stock alerts" do
    shampoo = product("shampoo")
    setting(shampoo, low: 10, reorder: 50)
    stock(shampoo, dest, 4)
    expect { suggestions }.not_to change { Inventory::LowStockQuery.new(business).alerts.map { |a| [ a.product.id, a.on_hand ] } }
  end
end
