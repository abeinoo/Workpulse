require "rails_helper"

# Approval (= the supplier is paid) refuses a receipt that would take more of a
# Purchase Request line than can still arrive: ordered − received (confirmed,
# non-voided) − other approved, not yet confirmed, non-voided receipts
# (PurchaseRequestItem.approvable_quantities), checked under the Purchase Request
# lock before anything is applied or paid. Confirmation stays the final stock
# guard (goods_receipt_poster_spec.rb).
RSpec.describe "Goods Receipt approval — quantity still approvable" do
  let(:business)  { create(:business) }
  let(:creator)   { create(:user, :super_admin, business: business) }
  let(:approver)  { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 100) }
  let(:other)     { business.products.create!(name: "Gadget", sku: "G-1", average_cost_price: 50) }

  let(:request) do
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: creator)
    pr.items.build(product: product, quantity: 10, unit_price: 100, supplier: supplier)
    pr.items.build(product: other, quantity: 10, unit_price: 50, supplier: supplier)
    pr.save!
    pr.update_column(:status, "approved")
    pr.reload
  end

  def line(prod = product) = request.items.find_by!(product: prod)

  # A receipt awaiting approval, paid in company cash at approval. Saved like a
  # draft made while the quantity was still free (the soft check passes).
  def pending_receipt(lines)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: request, created_by: creator, funding_source_kind: "company_cash")
    lines.each { |prod, qty| receipt.items.build(product: prod, quantity: qty, unit_cost: 100, purchase_request_item: line(prod)) }
    receipt.save!
    receipt.update_column(:approval_status, "pending_approval")
    receipt
  end

  def approve(receipt, actor: approver) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: actor).approve!

  def confirm(receipt) = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: approver).call

  def message(prod, available)
    I18n.t("inventory.goods_receipts.errors.exceeds_approvable_quantity", product: prod.name, available: available)
  end

  def approvable(except_receipt_id:) = PurchaseRequestItem.approvable_quantities([ line ], except_receipt_id: except_receipt_id).fetch(line.id)

  def untouched?(receipt)
    receipt.reload
    receipt.approval_pending_approval? && receipt.decided_at.nil? &&
      FinancialSettlement.where(settleable: receipt).none? &&
      AuditLog.where(auditable: receipt, action: "approve").none?
  end

  describe "sequential approvals" do
    it "two receipts for the same 10: the first is approved and paid, the second refused with nothing applied" do
      first  = pending_receipt([ [ product, 10 ] ])
      second = pending_receipt([ [ product, 10 ] ])

      expect(approve(first)).to be_ok
      expect(FinancialSettlement.where(settleable: first).sum(:amount)).to eq(1000)

      result = approve(second)
      expect(result).not_to be_ok
      expect(result.error).to eq(message(product, "0"))
      expect(untouched?(second)).to be(true)
    end

    it "partial receipts share the line: 6 approved leaves 4 approvable" do
      pending_receipt([ [ product, 6 ] ]).then { |r| expect(approve(r)).to be_ok }

      expect(approve(pending_receipt([ [ product, 5 ] ])).error).to eq(message(product, "4"))
      expect(approve(pending_receipt([ [ product, 4 ] ]))).to be_ok
    end

    it "counts confirmed receipts once (an approved receipt being confirmed moves buckets, never doubles)" do
      first = pending_receipt([ [ product, 6 ] ])
      approve(first)
      expect(approvable(except_receipt_id: 0)).to eq(4)
      expect(confirm(first)).to be_ok
      expect(approvable(except_receipt_id: 0)).to eq(4)
    end

    it "never counts voided, rejected or still-pending receipts, nor the receipt being approved" do
      voided = pending_receipt([ [ product, 10 ] ])
      approve(voided)
      expect(Inventory::GoodsReceiptVoider.new(goods_receipt_id: voided.id, actor: approver, reason: "wrong").call).to be_ok
      pending_receipt([ [ product, 10 ] ]) # pending approval: not paid, not counted

      mine = pending_receipt([ [ product, 10 ] ])
      expect(approvable(except_receipt_id: mine.id)).to eq(10)
      expect(approve(mine)).to be_ok
    end

    it "a line listed twice on one receipt is checked as its total" do
      pending_receipt([ [ product, 6 ] ]).then { |r| approve(r) }
      twice = pending_receipt([ [ product, 3 ], [ product, 3 ] ]) # 6 > 4 approvable

      expect(approve(twice).error).to eq(message(product, "4"))
      expect(untouched?(twice)).to be(true)
    end

    it "every line is checked; one line over refuses the whole approval" do
      pending_receipt([ [ other, 8 ] ]).then { |r| approve(r) }
      both = pending_receipt([ [ product, 5 ], [ other, 3 ] ])

      expect(approve(both).error).to eq(message(other, "2"))
      expect(untouched?(both)).to be(true)
    end

    it "a receipt not from a Purchase Request is unaffected" do
      plain = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            created_by: creator, funding_source_kind: "company_cash")
      plain.items.build(product: product, quantity: 99, unit_cost: 1)
      plain.save!
      plain.update_column(:approval_status, "pending_approval")
      expect(approve(plain)).to be_ok
    end
  end

  describe "concurrent approvals (two connections)" do
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

    it "two receipts competing for the same 10: one approved and paid; the other waits on the request, then is refused" do
      first  = pending_receipt([ [ product, 10 ] ])
      second = pending_receipt([ [ product, 10 ] ])

      # Hold the first approval inside its locks (request locked, nothing paid yet).
      reached = Queue.new
      release = Queue.new
      calls   = 0
      allow(Inventory::PurchaseRequestAdvanceAllocator).to receive(:new).and_wrap_original do |original, *args|
        if (calls += 1) == 1
          reached << true
          release.pop
        end
        original.call(*args)
      end

      a = on_other_connection { approve(first) }
      Timeout.timeout(10) { reached.pop }
      b = on_other_connection { approve(second) }
      wait_for_lock_wait("%purchase_requests%FOR UPDATE%") # the second waits on the request lock
      release << true

      results = [ a, b ].map { |t| t.join(10).value }
      expect(results.count(&:ok?)).to eq(1)
      expect(results.reject(&:ok?).map(&:error)).to eq([ message(product, "0") ])
      expect(FinancialSettlement.where(settleable_type: "GoodsReceipt").sum(:amount)).to eq(1000) # paid once
      expect(GoodsReceipt.approval_approved.count).to eq(1)
    end
  end
end
