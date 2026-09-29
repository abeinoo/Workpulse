require "rails_helper"

RSpec.describe Inventory::StockTransferPoster, type: :model do
  let(:business) { create(:business) }
  let(:source)   { business.warehouses.create!(name: "Main") }
  let(:dest)     { business.warehouses.create!(name: "Branch") }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1",
                              initial_cost_price: 10, average_cost_price: 10)
  end

  def receive(qty:, cost:, wh:)
    r = business.goods_receipts.build(warehouse: wh, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: cost)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def transfer(qty:, from: source, to: dest)
    t = business.stock_transfers.build(source_warehouse: from, destination_warehouse: to,
                                       transferred_on: Date.current)
    t.items.build(product: product, quantity: qty)
    described_class.new(t).call
  end

  before { receive(qty: 10, cost: 10, wh: source) }

  it "moves stock from source to destination, leaving the total unchanged" do
    result = transfer(qty: 4)
    expect(result.ok?).to be(true)
    expect(product.stock_in(source)).to eq(6)
    expect(product.stock_in(dest)).to eq(4)
    expect(product.current_stock).to eq(10)
  end

  it "records a paired OUT and IN movement per item" do
    transfer(qty: 4)
    movements = product.inventory_movements.where(reason: %w[transfer_out transfer_in])
    expect(movements.where(reason: "transfer_out", warehouse: source).count).to eq(1)
    expect(movements.where(reason: "transfer_in",  warehouse: dest).count).to eq(1)
  end

  it "does not change the product's average cost" do
    expect { transfer(qty: 4) }.not_to change { product.reload.average_cost_price }
  end

  it "values the transfer at the current average cost" do
    result = transfer(qty: 4)
    expect(result.transfer.items.first.unit_cost).to eq(10)
  end

  it "blocks a transfer that exceeds source on-hand and records nothing" do
    result = transfer(qty: 11)
    expect(result.ok?).to be(false)
    expect(result.transfer.errors[:base].join).to match(/available/i)
    expect(product.stock_in(source)).to eq(10)
    expect(product.stock_in(dest)).to eq(0)
  end

  it "rejects a transfer to the same warehouse" do
    result = transfer(qty: 1, to: source)
    expect(result.ok?).to be(false)
    expect(result.transfer.errors[:destination_warehouse_id]).to be_present
  end

  describe "atomicity" do
    it "writes the transfer and both movements of every line together" do
      t = business.stock_transfers.build(source_warehouse: source, destination_warehouse: dest, transferred_on: Date.current)
      t.items.build(product: product, quantity: 2)
      t.items.build(product: product, quantity: 3)
      expect(described_class.new(t).call.ok?).to be(true)
      expect(t.inventory_movements.group(:direction).sum(:quantity)).to eq("out" => 5, "in" => 5)
    end

    # This file's own `receive(qty:, cost:, wh:)` helper shadows RSpec's.
    def rspec_receive(message) = RSpec::Mocks::ExampleMethods.instance_method(:receive).bind_call(self, message)

    it "a failure while posting the destination leg leaves no transfer and no movement" do
      calls = 0
      allow_any_instance_of(ActiveRecord::Associations::CollectionProxy).to rspec_receive(:create!).and_wrap_original do |m, *args, **kw|
        calls += 1
        raise ActiveRecord::RecordInvalid, InventoryMovement.new if calls == 2 # the IN leg
        m.call(*args, **kw)
      end

      expect { transfer(qty: 4) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(business.stock_transfers.count).to eq(0)
      expect(product.inventory_movements.where(reason: %w[transfer_in transfer_out])).to be_empty
      expect(product.stock_in(source)).to eq(10)
      expect(product.stock_in(dest)).to eq(0)
    end

    it "checks source stock inside the transaction, after locking the product rows" do
      sql = []
      logger = ->(*, payload) { sql << payload[:sql] }
      ActiveSupport::Notifications.subscribed(logger, "sql.active_record") { transfer(qty: 1) }
      lock_at  = sql.index { |q| q.include?("FROM \"products\"") && q.include?("FOR UPDATE") }
      check_at = sql.index { |q| q.include?("inventory_movements") && q.include?("SUM") }
      begin_at = sql.index { |q| q.match?(/BEGIN|SAVEPOINT/) }
      expect(lock_at).to be_present
      expect(begin_at).to be < lock_at
      expect(lock_at).to be < check_at
    end

    it "a second transfer sees the first one's stock and cannot overdraw the source" do
      expect(transfer(qty: 7).ok?).to be(true)
      second = transfer(qty: 7)
      expect(second.ok?).to be(false)
      expect(product.stock_in(source)).to eq(3)
    end
  end

  it "assigns a sequential TRF number" do
    result = transfer(qty: 1)
    expect(result.transfer.transfer_number).to match(/\ATRF-\d{6}\z/)
  end
end
