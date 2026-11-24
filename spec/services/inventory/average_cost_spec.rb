require "rails_helper"

# Average cost with posting-order semantics (W2) and its audit record
# (Decisions 17, 19).
RSpec.describe "Average cost (W2) and its audit" do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :owner, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { create(:branch, business: business) }
  let(:product)   { business.products.create!(name: "Oil", sku: "OIL-1", initial_cost_price: 0, average_cost_price: 0) }

  def receive!(qty, cost, actor: nil, on: Date.current)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: on)
    receipt.items.build(product: product, quantity: qty, unit_cost: cost)
    result = Inventory::GoodsReceiptPoster.new(receipt, actor: actor).call
    raise receipt.errors.full_messages.to_sentence unless result.ok?

    receipt
  end

  def issue!(qty, on: Date.current)
    issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: on)
    issue.items.build(product: product, quantity: qty)
    approve_and_post_stock_issue(issue)
    issue
  end

  def average = product.reload.average_cost_price

  it "every receipt blends at posting and writes one audit record (old, new, trigger, source, movement, actor)" do
    first = receive!(10, 100, actor: owner)
    receive!(10, 120, actor: owner)
    expect(average).to eq(110)
    changes = InventoryAverageCostChange.where(product: product).order(:id)
    expect(changes.map { |c| [ c.previous_average_cost, c.new_average_cost, c.trigger, c.system ] })
      .to eq([ [ 0, 100, "receipt_posted", false ], [ 100, 110, "receipt_posted", false ] ])
    expect(changes.first).to have_attributes(source: first, actor: owner, quantity: 10, on_hand_before: 0, unit_cost: 100)
    expect(changes.first.inventory_movement).to eq(InventoryMovement.find_by!(source: first))
    expect(AuditLog.where(auditable: product, action: "average_cost_changed").count).to eq(2)
  end

  it "an automated posting is marked as a system run, with the owner as the system actor" do
    owner
    receive!(5, 8)
    change = InventoryAverageCostChange.sole
    expect([ change.system, change.actor ]).to eq([ true, owner ])
    expect(AuditLog.find_by!(action: "average_cost_changed").metadata).to include("system" => true, "trigger" => "receipt_posted")
  end

  it "BUG-071: an issue is valued with the average read under the lock, not a product object loaded earlier" do
    stale = Product.find(product.id)                  # average 0 in memory
    receive!(10, 7)                                   # the committed average becomes 7
    issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    issue.items.build(product: stale, quantity: 2)
    expect(approve_and_post_stock_issue(issue)).to be_ok
    expect([ issue.items.sole.unit_cost, InventoryMovement.find_by!(source: issue).unit_cost ]).to eq([ 7, 7 ])
  end

  it "writes no record when the average does not change" do
    receive!(10, 5)
    expect { receive!(10, 5) }.not_to change(InventoryAverageCostChange, :count)
    expect(average).to eq(5)
  end

  it "keeps 8 decimal places (12 bottles at 25.00 = 0.07042254 per ml)" do
    receive!(4260, BigDecimal("0.07042254"))
    expect(average).to eq(BigDecimal("0.07042254"))
  end

  it "a back-dated document never re-costs earlier history: the order of posting decides (W2)" do
    receive!(4, 100, on: Date.current - 10)
    receive!(5, 82, on: Date.current - 5)                  # (4 × 100 + 5 × 82) / 9 = 90
    expect(average).to eq(90)
    issue!(1, on: Date.current - 20)                        # back-dated issue: no replay
    adjustment = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current, reason: "manual_correction", created_by: owner)
    adjustment.items.build(product: product, quantity_difference: 1)
    expect(Inventory::AdjustmentPoster.new(adjustment).call).to be_ok
    expect(average).to eq(90)                               # unchanged — no date-order recalculation
  end

  it "voiding a receipt unblends it at the void's posting time and is audited; earlier history is not replayed" do
    receive!(10, 100)
    second = receive!(10, 120)                              # 110
    issue!(5)                                               # 15 on hand at 110
    result = Inventory::GoodsReceiptVoider.new(goods_receipt_id: second.id, actor: owner, reason: "Duplicate").call
    expect(result).to be_ok
    expect(average).to eq(BigDecimal("90"))                 # (15 × 110 − 10 × 120) / 5
    expect(InventoryAverageCostChange.where(trigger: "document_voided").sole)
      .to have_attributes(previous_average_cost: 110, new_average_cost: 90, actor: owner, source: second)
  end

  it "a void that would make the average negative leaves it unchanged and still posts" do
    receive!(10, 10)
    big = receive!(10, 1000)                                # 505
    issue!(15)                                              # 5 left at 505
    receive!(10, 1)                                         # (5 × 505 + 10) / 15 = 169
    result = Inventory::GoodsReceiptVoider.new(goods_receipt_id: big.id, actor: owner, reason: "Wrong").call
    expect(result).to be_ok
    expect(average).to eq(169)                              # (15 × 169 − 10 × 1000) < 0 → unchanged
    expect(InventoryAverageCostChange.where(trigger: "document_voided")).to be_empty
  end

  it "rolls back the cost change and the receipt when the audit record cannot be written" do
    owner
    fail_audit_writes!(Inventory::AverageCost::AUDIT_ACTION)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: 10, unit_cost: 7)
    expect { Inventory::GoodsReceiptPoster.new(receipt).call }.to raise_error(AuditLoggable::AuditWriteFailed)
    expect([ average, product.current_stock, InventoryAverageCostChange.count ]).to eq([ 0, 0, 0 ])
  end

  it "an opening balance blends with its own trigger" do
    adjustment = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current, reason: "opening_balance", created_by: owner)
    adjustment.items.build(product: product, quantity_difference: 4, unit_cost: 25)
    expect(Inventory::AdjustmentPoster.new(adjustment).call).to be_ok
    expect(InventoryAverageCostChange.sole).to have_attributes(trigger: "opening_balance_posted", new_average_cost: 25, actor: owner)
  end

  describe "manual / batch recalculation (posting order)" do
    it "reproduces the posted average, writing nothing when it matches" do
      receive!(10, 100)
      receive!(10, 120)
      issue!(5)
      result = Inventory::ProductCostRecalculator.new(product, actor: owner).call
      expect([ result.status, result.average ]).to eq([ :unchanged, 110 ])
      expect(InventoryAverageCostChange.where(trigger: "manual_recalculation")).to be_empty
    end

    it "a replay that goes below zero stops for that product only, writes nothing and returns a diagnostic" do
      healthy = business.products.create!(name: "Soap", sku: "SO-1", initial_cost_price: 0, average_cost_price: 7)
      receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      receipt.items.build(product: healthy, quantity: 2, unit_cost: 9)
      Inventory::GoodsReceiptPoster.new(receipt).call
      healthy.update_columns(average_cost_price: 3) # a stale stored value the replay will correct

      # Historical data: stock left before any recorded inflow (inserted as a
      # legacy row would be — never through a posting service).
      InventoryMovement.create!(business: business, product: product, warehouse: warehouse, direction: :out,
                                reason: :laundry_consumption, quantity: 3, unit_cost: 0, occurred_on: Date.current)
      receive!(5, 10)
      before = average

      results = Inventory::ProductCostRecalculator.run([ product, healthy ], actor: owner)
      stopped, changed = results
      expect(stopped.status).to eq(:stopped)
      expect(stopped.diagnostic).to have_attributes(balance_before: 0, balance_after: -3, likely_cause: :historical_data,
                                                    ordering: Inventory::ProductCostRecalculator::ORDERING)
      expect(average).to eq(before)
      expect(InventoryAverageCostChange.where(product: product, trigger: "batch_replay")).to be_empty
      expect(changed.status).to eq(:changed)
      expect(healthy.reload.average_cost_price).to eq(9)
      expect(InventoryAverageCostChange.where(product: healthy, trigger: "batch_replay").sole.operation_ref).to start_with("recalculation:")
    end
  end

  it "the audit records are append-only" do
    receive!(1, 1)
    change = InventoryAverageCostChange.sole
    expect { change.update!(new_average_cost: 2) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { InventoryAverageCostChange.where(id: change.id).update_all(new_average_cost: 2) }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end
end
