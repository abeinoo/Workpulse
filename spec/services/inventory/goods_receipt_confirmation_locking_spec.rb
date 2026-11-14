require "rails_helper"

# Confirmation locks every Purchase Request line a receipt references in
# ascending id order (GoodsReceiptPoster), so two receipts sharing lines in
# opposite order serialize instead of deadlocking; if PostgreSQL still aborts a
# confirmation (deadlock / lock timeout), the user gets a retry message and
# nothing was posted — a manual retry posts the stock exactly once.
RSpec.describe "Goods Receipt confirmation — line locking" do
  let(:business)  { create(:business) }
  let(:creator)   { create(:user, :super_admin, business: business) }
  let(:approver)  { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:soap)      { business.products.create!(name: "Soap", sku: "S-1", average_cost_price: 5) }
  let(:towel)     { business.products.create!(name: "Towel", sku: "T-1", average_cost_price: 8) }

  let(:request) do
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: creator)
    pr.items.build(product: soap, quantity: 10, unit_price: 5, supplier: supplier)
    pr.items.build(product: towel, quantity: 10, unit_price: 8, supplier: supplier)
    pr.save!
    pr.update_column(:status, "approved")
    pr.reload
  end

  def line(product) = request.items.find_by!(product: product)

  # Approved and ready to confirm; lines in the given order (item ids follow it).
  def approved_receipt(products, quantity: 3)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: request, created_by: creator, funding_source_kind: "supplier_credit")
    products.each { |p| receipt.items.build(product: p, quantity: quantity, unit_cost: 1, purchase_request_item: line(p)) }
    receipt.save!
    receipt.update_column(:approval_status, "approved")
    receipt
  end

  def confirm(receipt) = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: approver).call

  it "locks the referenced lines in one ascending-id FOR UPDATE, whatever the receipt's line order" do
    reversed = approved_receipt([ towel, soap ]) # towel's line first on the receipt
    expect(line(soap).id).to be < line(towel).id

    locks = []
    collect = ->(*, payload) { locks << payload[:sql] if payload[:sql] =~ /FOR UPDATE/ && payload[:sql].include?("purchase_request_items") }
    ActiveSupport::Notifications.subscribed(collect, "sql.active_record") { expect(confirm(reversed)).to be_ok }

    expect(locks.size).to eq(1)
    expect(locks.first).to match(/ORDER BY "purchase_request_items"\."id" ASC/)
  end

  it "a deadlock or lock timeout returns a retry message, posts nothing, and a manual retry posts exactly once" do
    receipt = approved_receipt([ soap ])
    calls = 0
    allow_any_instance_of(Inventory::GoodsReceiptPoster).to receive(:call).and_wrap_original do |original, *args|
      raise ActiveRecord::Deadlocked, "deadlock detected" if (calls += 1) == 1

      original.call(*args)
    end

    result = confirm(receipt)
    expect(result).not_to be_ok
    expect(result.error).to eq(I18n.t("inventory.goods_receipts.errors.confirmation_busy"))
    expect(receipt.reload).to be_draft
    expect(InventoryMovement.where(source: receipt)).to be_empty

    expect(confirm(receipt)).to be_ok
    expect(InventoryMovement.where(source: receipt).sum(:quantity)).to eq(3)
    expect(confirm(receipt)).not_to be_ok # never twice
    expect(InventoryMovement.where(source: receipt).sum(:quantity)).to eq(3)
    expect(line(soap).received_quantity).to eq(3)
  end

  describe "two receipts sharing two lines in opposite order (two connections)" do
    include_context "non-transactional database"

    def on_other_connection(&block)
      Thread.new { ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true, &block) }
            .tap { |t| t.report_on_exception = false }
    end

    def wait_for_lock_wait(pattern)
      Timeout.timeout(10) do
        loop do
          waiting = ActiveRecord::Base.connection.select_value(<<~SQL)
            SELECT COUNT(*) FROM pg_stat_activity
             WHERE wait_event_type = 'Lock' AND query ILIKE #{ActiveRecord::Base.connection.quote(pattern)}
          SQL
          break if waiting.to_i.positive?

          sleep 0.05
        end
      end
    end

    it "serialize on the first line instead of deadlocking; both post, never beyond the ordered quantity" do
      forward  = approved_receipt([ soap, towel ])
      backward = approved_receipt([ towel, soap ])

      # Hold the first confirmation after it locked both lines, before posting.
      reached = Queue.new
      release = Queue.new
      calls   = 0
      allow_any_instance_of(Inventory::GoodsReceiptPoster).to receive(:post_item).and_wrap_original do |original, *args|
        if (calls += 1) == 1
          reached << true
          release.pop
        end
        original.call(*args)
      end

      a = on_other_connection { confirm(forward) }
      Timeout.timeout(10) { reached.pop }
      b = on_other_connection { confirm(backward) }
      wait_for_lock_wait("%purchase_request_items%FOR UPDATE%")
      release << true

      expect([ a, b ].map { |t| t.join(10).value }).to all(be_ok)
      expect([ line(soap), line(towel) ].map(&:received_quantity)).to eq([ 6, 6 ])
      expect(soap.reload.current_stock).to eq(6)
      expect(towel.reload.current_stock).to eq(6)
    end
  end
end
