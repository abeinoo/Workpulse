require "rails_helper"

# End-to-end multi-unit workflows through the real posting services
# (docs/inventory/multi_unit_nested_packaging_design.md §7 – §10, Appendix A). Quantities are always
# checked on both ledgers: inventory_movements (total, cost) and the derived
# packaging state (sealed packages per level + loose content).
RSpec.describe "Multi-unit and nested packaging workflows" do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:annex)    { business.warehouses.create!(name: "Annex") }
  let(:branch)   { create(:branch, business: business) }
  let(:supplier) { business.suppliers.create!(name: "Acme") }

  # 1 box = 10 pcs, 1 carton = 12 boxes = 120 pcs.
  let(:razor) do
    product = business.products.create!(name: "Razor", sku: "RZ-1", initial_cost_price: 0, average_cost_price: 0, unit_of_measure: "pieces")
    configure_packaging!(product, owner, [ "box", 10 ], [ "carton", 12 ])
  end
  # 1 bottle = 355 ml.
  let(:shampoo) do
    product = business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0, unit_of_measure: "ml")
    configure_packaging!(product, owner, [ "bottle", 355 ])
  end

  def issue!(warehouse, lines)
    issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    lines.each do |product, unit, amount|
      issue.items.build(product: product, entered_quantity: amount, packaging_level: unit && level_of(product, unit))
    end
    [ issue, approve_and_post_stock_issue(issue) ]
  end

  def transfer!(lines, from: main, to: annex)
    transfer = business.stock_transfers.build(source_warehouse: from, destination_warehouse: to, transferred_on: Date.current, created_by: owner)
    lines.each do |product, unit, amount|
      transfer.items.build(product: product, entered_quantity: amount, packaging_level: unit && level_of(product, unit))
    end
    [ transfer, Inventory::StockTransferPoster.new(transfer).call ]
  end

  def value(product) = product.reload.current_stock * product.average_cost_price

  describe "receiving" do
    it "receives full cartons, boxes instead of cartons and mixed units; unit cost is per the entered unit" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 2, 120 ], [ "box", 3, 10 ], [ nil, 5, 1 ] ])
      expect(packaging_state(razor, main)).to eq("carton" => 2, "box" => 3, loose: 5, total: 275)
      expect(razor.reload.average_cost_price).to eq(1)          # 120 / 120 pcs, 10 / 10 pcs, 1 / pc
      item = GoodsReceiptItem.find_by!(packaging_level: level_of(razor, "carton"))
      expect([ item.quantity, item.unit_cost, item.total_cost ]).to eq([ 240, 1, 240 ])
    end

    it "against a purchase request in cartons: partial, mixed-unit and multiple receipts; remaining in base units; over-receipt refused" do
      request = business.purchase_requests.create!(warehouse: main, created_by: owner, status: "approved", approved_at: Time.current,
                                                   items_attributes: [ { product_id: razor.id, entered_quantity: 2,
                                                                         packaging_level_id: level_of(razor, "carton").id, entered_unit_price: 120 } ])
      line = request.items.sole
      expect([ line.quantity, line.unit_price ]).to eq([ 240, 1 ])

      receipt = business.goods_receipts.build(warehouse: main, received_on: Date.current, purchase_request: request, supplier: supplier)
      receipt.items.build(product: razor, purchase_request_item: line, entered_quantity: 1, packaging_level: level_of(razor, "carton"), entered_unit_cost: 120)
      receipt.items.build(product: razor, purchase_request_item: line, entered_quantity: 6, packaging_level: level_of(razor, "box"), entered_unit_cost: 10)
      expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
      expect(line.reload.remaining_quantity).to eq(60)            # 240 − 180 = 0.5 carton
      expect(Inventory::Packaging::Format.in_purchase_unit(line.remaining_quantity, level_of(razor, "carton"))).to eq(BigDecimal("0.5"))

      second = business.goods_receipts.build(warehouse: main, received_on: Date.current, purchase_request: request, supplier: supplier)
      second.items.build(product: razor, purchase_request_item: line, entered_quantity: 7, packaging_level: level_of(razor, "box"), entered_unit_cost: 10)
      expect(Inventory::GoodsReceiptPoster.new(second).call).not_to be_ok # 70 > 60 remaining, checked in base units
      expect(second.errors.full_messages.join).to include("60")
      expect(line.reload.remaining_quantity).to eq(60)
      expect(packaging_state(razor, main)).to eq("carton" => 1, "box" => 6, loose: 0, total: 180)
    end

    it "shows the remaining purchase quantity truncated, never overstated (113 of 120 pcs → 0.941 carton)" do
      expect(Inventory::Packaging::Format.in_purchase_unit(113, level_of(razor, "carton"))).to eq(BigDecimal("0.941"))
      expect(Inventory::Packaging::Format.in_purchase_unit(155, level_of(shampoo, "bottle"))).to eq(BigDecimal("0.436"))
    end
  end

  describe "issuing" do
    before { receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 1, 120 ] ]) }

    it "a strict full-carton issue takes the carton; a strict box issue opens the carton once" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 1, 120 ] ])
      _, result = issue!(main, [ [ razor, "carton", 1 ] ])
      expect(result).to be_ok
      expect(packaging_state(razor, main)).to eq("carton" => 1, "box" => 0, loose: 0, total: 120)

      _, result = issue!(main, [ [ razor, "box", 3 ] ])
      expect(result).to be_ok
      expect(packaging_state(razor, main)).to eq("carton" => 0, "box" => 9, loose: 0, total: 90)
    end

    it "a carton is never assembled from boxes: 12 loose boxes (120 pcs) refuse a 1-carton request" do
      issue!(main, [ [ razor, "box", 3 ] ])                                  # 9 boxes
      receive_units!(product: razor, warehouse: main, lines: [ [ "box", 3, 10 ] ]) # 12 boxes = 120 pcs
      issue, result = issue!(main, [ [ razor, "carton", 1 ] ])
      expect(result).not_to be_ok                                          # enough pieces, no sealed carton
      expect(result.issue.errors.full_messages.join).to include("needs 1 carton as full packages", "12 boxes")
      expect(issue.reload).to be_approved
    end

    it "loose pieces never satisfy a sealed box request; the issue stays approved and reserved" do
      issue!(main, [ [ razor, nil, 115 ] ])                      # 0 cartons, 0 boxes + 5 pcs loose
      expect(packaging_state(razor, main)).to eq("carton" => 0, "box" => 0, loose: 5, total: 5)
      issue, result = issue!(main, [ [ razor, "box", 1 ] ])
      expect(result).not_to be_ok
      expect(issue.reload).to be_approved
      expect(InventoryMovement.where(source: issue)).to be_empty
    end

    it "a base-unit issue takes loose first, then opens the fewest packages" do
      issue!(main, [ [ razor, "box", 3 ] ])                       # 9 boxes (90)
      issue!(main, [ [ razor, nil, 15 ] ])                        # opens 2 boxes → 7 boxes + 5 pcs (75)
      expect(packaging_state(razor, main)).to eq("carton" => 0, "box" => 7, loose: 5, total: 75)
      issue!(main, [ [ razor, nil, 5 ] ])                         # loose only, no box opened
      expect(packaging_state(razor, main)).to eq("carton" => 0, "box" => 7, loose: 0, total: 70)
      receive_units!(product: razor, warehouse: main, lines: [ [ nil, 5, 1 ] ])
      issue!(main, [ [ razor, nil, 15 ] ])                        # 5 loose + 1 box (9 boxes + 5 → 95 − 15 = 80)
      expect(packaging_state(razor, main)).to eq("carton" => 0, "box" => 6, loose: 0, total: 60)
    end

    it "opening packages changes neither the total nor the value — only the consumed quantity leaves" do
      before_value = value(razor)
      issue!(main, [ [ razor, nil, 1 ] ])
      expect(value(razor)).to eq(before_value - razor.average_cost_price)
      expect(InventoryAverageCostChange.where(product: razor).count).to eq(1) # the receipt only
    end
  end

  describe "transferring (scenarios A – E)" do
    it "A: 2 of 10 sealed cartons arrive as 2 sealed cartons, nothing opened, total and value preserved" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 10, 120 ] ])
      value_before = value(razor)
      _, result = transfer!([ [ razor, "carton", 2 ] ])
      expect(result).to be_ok
      expect(packaging_state(razor, main)).to eq("carton" => 8, "box" => 0, loose: 0, total: 960)
      expect(packaging_state(razor, annex)).to eq("carton" => 2, "box" => 0, loose: 0, total: 240)
      expect(value(razor)).to eq(value_before)
      expect(InventoryPackagingEntry.where(kind: "breakdown")).to be_empty
    end

    it "B: 5 boxes from 3 sealed cartons opens one carton; 5 sealed boxes arrive" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 3, 120 ] ])
      transfer!([ [ razor, "box", 5 ] ])
      expect(packaging_state(razor, main)).to eq("carton" => 2, "box" => 7, loose: 0, total: 310)
      expect(packaging_state(razor, annex)).to eq("carton" => 0, "box" => 5, loose: 0, total: 50)
    end

    it "C: 3 of 12 sealed bottles arrive sealed; D: 100 ml opens one bottle and arrives loose" do
      receive_units!(product: shampoo, warehouse: main, lines: [ [ "bottle", 12, 25 ] ])
      value_before = value(shampoo)
      transfer!([ [ shampoo, "bottle", 3 ] ])
      expect(packaging_state(shampoo, main)).to eq("bottle" => 9, loose: 0, total: 3195)
      expect(packaging_state(shampoo, annex)).to eq("bottle" => 3, loose: 0, total: 1065)

      transfer!([ [ shampoo, nil, 100 ] ])
      expect(packaging_state(shampoo, main)).to eq("bottle" => 8, loose: 255, total: 3095)
      expect(packaging_state(shampoo, annex)).to eq("bottle" => 3, loose: 100, total: 1165)
      expect(shampoo.reload.current_stock).to eq(4260)
      expect(value(shampoo)).to eq(value_before)
    end

    it "E: one transfer with a carton of razors, 3 boxes of another product and 100 ml of shampoo" do
      gloves = configure_packaging!(business.products.create!(name: "Gloves", sku: "GL-1", initial_cost_price: 0, average_cost_price: 0),
                                    owner, [ "box", 50 ])
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 2, 120 ] ])
      receive_units!(product: gloves, warehouse: main, lines: [ [ "box", 4, 50 ] ])
      receive_units!(product: shampoo, warehouse: main, lines: [ [ "bottle", 2, 25 ] ])
      transfer, result = transfer!([ [ razor, "carton", 1 ], [ gloves, "box", 3 ], [ shampoo, nil, 100 ] ])
      expect(result).to be_ok
      expect(packaging_state(razor, annex)).to eq("carton" => 1, "box" => 0, loose: 0, total: 120)
      expect(packaging_state(gloves, annex)).to eq("box" => 3, loose: 0, total: 150)
      expect(packaging_state(shampoo, annex)).to eq("bottle" => 0, loose: 100, total: 100)
      expect(packaging_state(shampoo, main)).to eq("bottle" => 1, loose: 255, total: 610)
      expect(AuditLog.where(auditable: transfer, action: "post").sole.metadata["lines"].size).to eq(3) # BUG-074
    end

    it "refuses insufficient packages and reserved stock, leaving no movement or entry" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 1, 120 ] ])
      _, result = transfer!([ [ razor, "carton", 2 ] ])
      expect(result).not_to be_ok

      reserved = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current)
      reserved.items.build(product: razor, quantity: 100)
      save_stock_issue_in_status!(reserved, :approved)
      transfer, result = transfer!([ [ razor, "box", 3 ] ])     # 120 − 30 < 100 reserved
      expect(result).not_to be_ok
      expect(transfer.errors.full_messages.join).to include(reserved.issue_number)
      expect(InventoryMovement.where(source_type: "StockTransfer")).to be_empty
      expect(InventoryPackagingEntry.where(source_type: "StockTransfer")).to be_empty
    end

    it "a void returns the sealed packages to the source and removes them from the destination, audited (BUG-074)" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 3, 120 ] ])
      transfer, = transfer!([ [ razor, "box", 5 ] ])
      result = Inventory::DocumentVoider.new(transfer, user: owner, reason: "Wrong branch").call
      expect(result).to be_ok
      expect(packaging_state(razor, annex)).to eq("carton" => 0, "box" => 0, loose: 0, total: 0)
      expect(packaging_state(razor, main)).to eq("carton" => 2, "box" => 12, loose: 0, total: 360) # never resealed
      expect(AuditLog.where(auditable: transfer, action: "void").count).to eq(1)
    end
  end

  describe "stocktake (Decision 4)" do
    let(:counter)  { user_with_stock_permissions(business, :view_inventory, :manage_stock_counts) }
    let(:approver) { user_with_stock_permissions(business, :view_inventory, :post_stock_counts) }
    let(:bottle)   { level_of(shampoo, "bottle").id.to_s }

    before { receive_units!(product: shampoo, warehouse: main, lines: [ [ "bottle", 8, 25 ], [ nil, 300, 0.07 ] ]) } # 8 + 300 = 3140

    def count_with(breakdown)
      count = record_stock_count!(business: business, warehouse: main, counter: counter, lines: [])
      result = Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: counter,
                                                 entries: [ { product_id: shampoo.id, counted_breakdown: breakdown, entered: "1" } ]).call
      raise result.error unless result.ok?

      complete_stock_count!(count, counter)
      count.reload
    end

    it "no difference: approved with no adjustment and no entry" do
      count = count_with(bottle => "8", "loose" => "300")
      expect { expect(approve_stock_count(count, approver)).to be_ok }.not_to change(InventoryPackagingEntry, :count)
      expect(count.stock_adjustments).to be_empty
    end

    it "packaging only: a zero line, count_correction entries and no movement; reopening restores the packaging" do
      count = count_with(bottle => "7", "loose" => "655")
      expect { expect(approve_stock_count(count, approver)).to be_ok }.not_to change(InventoryMovement, :count)
      line = count.stock_adjustments.sole.items.sole
      expect([ line.quantity_difference, line.packaging_level_differences ]).to eq([ 0, { level_of(shampoo, "bottle").id => -1 } ])
      expect(packaging_state(shampoo, main)).to eq("bottle" => 7, loose: 655, total: 3140)

      expect(reopen_stock_count(count, approver)).to be_ok
      expect(packaging_state(shampoo, main)).to eq("bottle" => 8, loose: 300, total: 3140)
    end

    it "quantity only and combined differences post one movement each" do
      count = count_with(bottle => "8", "loose" => "290")         # −10, packaging unchanged
      expect(approve_stock_count(count, approver)).to be_ok
      expect(packaging_state(shampoo, main)).to eq("bottle" => 8, loose: 290, total: 3130)

      count = count_with(bottle => "7", "loose" => "600")         # −1 bottle and −45 ml in total
      expect(approve_stock_count(count, approver)).to be_ok
      expect(packaging_state(shampoo, main)).to eq("bottle" => 7, loose: 600, total: 3085)
      expect(InventoryMovement.where(source: count.stock_adjustments.sole).sole.quantity).to eq(45)
    end

    it "zero adjustment lines stay refused outside a stock count with a packaging difference" do
      manual = business.stock_adjustments.build(warehouse: main, adjusted_on: Date.current, reason: "damaged", created_by: owner)
      manual.items.build(product: shampoo, quantity_difference: 0, packaging_differences: { bottle => -1 })
      expect(manual).not_to be_valid
      expect(manual.items.first.errors[:packaging_differences]).to be_present
      plain = business.stock_adjustments.build(warehouse: main, adjusted_on: Date.current, reason: "damaged", created_by: owner)
      plain.items.build(product: shampoo, quantity_difference: 0)
      expect(Inventory::AdjustmentPoster.new(plain).call).not_to be_ok
    end
  end

  describe "voids (Decision 5)" do
    it "voiding a receipt after packages were opened restores free packages and removes the rest as base units" do
      r1 = receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 5, 120 ] ])
      issue!(main, [ [ razor, "box", 15 ] ])                      # 3 cartons + 9 boxes (450)
      receive_units!(product: razor, warehouse: main, lines: [ [ "box", 20, 10 ] ]) # 3 cartons + 29 boxes (650)
      expect(packaging_state(razor, main)).to eq("carton" => 3, "box" => 29, loose: 0, total: 650)

      result = Inventory::GoodsReceiptVoider.new(goods_receipt_id: r1.id, actor: owner, reason: "Duplicate").call
      expect(result).to be_ok
      expect(packaging_state(razor, main)).to eq("carton" => 0, "box" => 5, loose: 0, total: 50)
      expect(InventoryMovement.where(source: r1).count).to eq(2) # original kept + reversal
    end

    it "voiding an issue returns its packages sealed and its base quantity loose" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 1, 120 ] ])
      issue, = issue!(main, [ [ razor, "box", 3 ] ])
      expect(Inventory::DocumentVoider.new(issue, user: owner, reason: "Returned").call).to be_ok
      expect(packaging_state(razor, main)).to eq("carton" => 0, "box" => 12, loose: 0, total: 120)
      expect(AuditLog.where(auditable: issue, action: "void").count).to eq(1)       # BUG-074
    end
  end

  it "products without packaging behave exactly as before: no entries, no unit" do
    plain = business.products.create!(name: "Chair", sku: "CH-1", initial_cost_price: 0, average_cost_price: 0)
    receipt = business.goods_receipts.build(warehouse: main, received_on: Date.current)
    receipt.items.build(product: plain, quantity: 4, unit_cost: 10)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
    _, result = transfer!([ [ plain, nil, 3 ] ])
    expect(result).to be_ok
    expect(InventoryPackagingEntry.where(product: plain)).to be_empty
    expect([ plain.stock_in(main), plain.stock_in(annex) ]).to eq([ 1, 3 ])
  end
end
