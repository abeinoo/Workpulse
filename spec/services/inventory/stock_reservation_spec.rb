require "rails_helper"

# Stock reservation lifecycle for stock issues (see Inventory::StockAvailability):
# approval reserves, confirmation consumes, cancellation releases —
# available = on-hand − quantities on OTHER approved issues, per product and
# warehouse.
RSpec.describe "Stock issue reservations", type: :model do
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:approver)  { create(:user, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:sugar)     { business.products.create!(name: "Sugar", sku: "SUG-1", initial_cost_price: 10, average_cost_price: 10) }

  def receive!(qty, product: sugar, into: warehouse)
    r = business.goods_receipts.build(warehouse: into, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 10)
    expect(Inventory::GoodsReceiptPoster.new(r).call).to be_ok
  end

  def build_issue(qty, product: sugar, from: warehouse, status: :pending_approval)
    i = business.stock_issues.build(warehouse: from, branch: branch, issued_on: Date.current, created_by: requester)
    i.items.build(product: product, quantity: qty)
    if status != :draft
      i.submitted_by = requester
      i.submitted_at = Time.current
    end
    i.status = status
    i.save!
    i
  end

  def approve(issue)  = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!
  def reject(issue)   = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).reject!(reason: "no")
  def confirm(issue)  = Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call
  def cancel(issue)   = Inventory::StockIssueCancellation.new(stock_issue_id: issue.id, actor: requester, reason: "not needed").call

  def reserved(product: sugar, in_warehouse: warehouse)
    Inventory::StockAvailability.reserved_by(warehouse_ids: in_warehouse.id, product_ids: product.id)
                                .fetch([ in_warehouse.id, product.id ], 0).to_d
  end

  describe "reservation" do
    it "does not reserve stock for drafts or issues pending approval" do
      receive!(2)
      build_issue(5, status: :draft)
      build_issue(5)

      expect(reserved).to eq(0)
      line = Inventory::StockAvailability.lines_for(build_issue(2)).sole
      expect([ line.on_hand, line.reserved, line.available, line.shortfall? ]).to eq([ 2, 0, 2, false ])
    end

    it "reserves the requested quantities on approval and records them on the audit entry" do
      receive!(2)
      issue = build_issue(1)

      expect(approve(issue)).to be_ok
      expect(reserved).to eq(1)
      expect(sugar.reload.current_stock).to eq(2) # reserved, not deducted

      log = AuditLog.for_auditable(issue).find_by(action: "approve")
      expect(log.metadata["reserved"]).to eq(sugar.id.to_s => "1.0")
    end

    it "lets two one-unit issues reserve two units, then refuses a third with a clear message" do
      receive!(2)
      first, second, third = Array.new(3) { build_issue(1) }

      expect(approve(first)).to be_ok
      expect(approve(second)).to be_ok

      result = approve(third)
      expect(result).not_to be_ok
      expect(result.error).to include("Not enough available stock for Sugar (SUG-1)")
      expect(result.error).to include("Available to issue: 0, requested: 1")
      expect(result.error).to include("Other approved stock issues have already reserved 2 of the 2 on hand")
      expect(third.reload).to be_pending_approval
      expect(third.approved_by).to be_nil
      expect(reserved).to eq(2)
      expect(AuditLog.for_auditable(third).where(action: "approve")).to be_empty
    end

    it "explains the shortage in Arabic" do
      receive!(2)
      2.times { approve(build_issue(1)) }

      error = I18n.with_locale(:ar) { approve(build_issue(1)).error }
      expect(error).to include("المخزون المتاح غير كافٍ")
      expect(error).to include("الكمية المتاحة للصرف: 0، والكمية المطلوبة: 1")
      expect(error).to include("توجد أذونات صرف أخرى معتمدة حجزت")
    end

    it "is all-or-nothing across lines: one short product blocks the whole approval" do
      shampoo = business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5)
      receive!(5)
      issue = build_issue(1)
      issue.items.create!(product: shampoo, quantity: 1) # none on hand

      result = approve(issue)
      expect(result).not_to be_ok
      expect(result.error).to include("Not enough stock for Shampoo (SH-1): 0 available, 1 requested")
      expect(issue.reload).to be_pending_approval
      expect(reserved).to eq(0)
    end

    it "releases the reservation when an approved issue is cancelled" do
      receive!(1)
      held, waiting = build_issue(1), build_issue(1)
      approve(held)
      expect(approve(waiting)).not_to be_ok

      expect(cancel(held)).to be_ok
      expect(reserved).to eq(0)
      expect(AuditLog.for_auditable(held).find_by(action: "cancel").metadata["reservation_released"]).to be(true)

      expect(approve(waiting)).to be_ok
    end

    it "rejects only from pending approval (no reservation), and never releases an approved issue's reservation" do
      receive!(2)
      pending  = build_issue(1)
      approved = build_issue(1)
      approve(approved)

      expect(reject(pending)).to be_ok
      expect(reserved).to eq(1)

      expect(reject(approved)).not_to be_ok
      expect(approved.reload).to be_approved
      expect(reserved).to eq(1)
    end

    it "never changes an approved issue's lines in place: editing releases the reservation and returns it to draft" do
      receive!(5)
      issue = build_issue(2)
      expect(approve(issue)).to be_ok
      expect(reserved).to eq(2)

      result = Inventory::StockIssueEditor.new(
        stock_issue_id: issue.id, actor: requester, lock_token: issue.reload.lock_token,
        attributes: { items_attributes: { "0" => { id: issue.items.first.id, product_id: sugar.id, quantity: 4 } } }
      ).call

      expect(result).to be_ok
      expect(issue.reload).to be_draft
      expect(reserved).to eq(0) # nothing reserved for lines nobody approved
      expect(issue.items.first.quantity.to_i).to eq(4)
    end

    it "makes newly received stock available to issues that were short" do
      receive!(1)
      approve(build_issue(1))
      short = build_issue(1)
      expect(approve(short)).not_to be_ok

      receive!(1)
      expect(approve(short)).to be_ok
    end

    it "isolates reservations by product and by warehouse" do
      other_warehouse = business.warehouses.create!(name: "Annex")
      shampoo = business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5)
      receive!(1)
      receive!(1, into: other_warehouse)
      receive!(1, product: shampoo)

      expect(approve(build_issue(1))).to be_ok
      expect(approve(build_issue(1, from: other_warehouse))).to be_ok
      expect(approve(build_issue(1, product: shampoo))).to be_ok

      expect(reserved).to eq(1)
      expect(reserved(in_warehouse: other_warehouse)).to eq(1)
      expect(reserved(product: shampoo)).to eq(1)
    end

    it "does not count voided or issued documents as reservations" do
      receive!(3)
      issued = build_issue(1)
      approve(issued)
      confirm(issued)

      expect(reserved).to eq(0)
      expect(sugar.reload.current_stock).to eq(2)
    end
  end

  describe "confirmation" do
    it "deducts physical stock exactly once and consumes, not double-counts, the reservation" do
      receive!(2)
      first, second = build_issue(1), build_issue(1)
      approve(first)
      approve(second)

      expect(confirm(first)).to be_ok
      expect(sugar.reload.current_stock).to eq(1)
      expect(reserved).to eq(1) # only `second` still holds stock

      expect(confirm(second)).to be_ok
      expect(sugar.reload.current_stock).to eq(0)
      expect(reserved).to eq(0)
    end

    it "is idempotent: retrying confirmation never deducts again" do
      receive!(2)
      issue = build_issue(1)
      approve(issue)
      confirm(issue)

      retry_result = nil
      expect { retry_result = confirm(issue) }.not_to change(InventoryMovement, :count)
      expect(retry_result).not_to be_ok
      expect(sugar.reload.current_stock).to eq(1)
      expect(AuditLog.for_auditable(issue).where(action: "confirm").count).to eq(1)
    end

    it "refuses to take stock reserved by another approved issue, leaving everything consistent" do
      receive!(2)
      first, second = build_issue(1), build_issue(1)
      approve(first)
      approve(second)
      # A count/adjustment shrinks on-hand below the reservations after approval.
      business.inventory_movements.create!(product: sugar, warehouse: warehouse, direction: :out,
                                           reason: :adjustment, quantity: 1, occurred_on: Date.current)

      result = confirm(first)
      expect(result).not_to be_ok
      expect(result.error).to include("Other approved stock issues have already reserved 1 of the 1 on hand")
      expect(first.reload).to be_approved
      expect(first.inventory_movements).to be_empty
      expect(sugar.reload.current_stock).to eq(1)
      expect(reserved).to eq(2)

      cancel(second)
      expect(confirm(first)).to be_ok
      expect(sugar.reload.current_stock).to eq(0)
    end

    it "cannot confirm a cancelled or rejected issue" do
      receive!(5)
      cancelled = build_issue(1)
      approve(cancelled)
      cancel(cancelled)
      rejected = build_issue(1)
      reject(rejected)

      [ cancelled, rejected ].each do |issue|
        expect(confirm(issue)).not_to be_ok
        expect(issue.reload.inventory_movements).to be_empty
      end
      expect(sugar.reload.current_stock).to eq(5)
    end

    it "cannot cancel an issue once it has been issued" do
      receive!(1)
      issue = build_issue(1)
      approve(issue)
      confirm(issue)

      expect(cancel(issue)).not_to be_ok
      expect(issue.reload).to be_issued
    end
  end

  describe "repeated requests" do
    it "a repeated approval neither re-reserves nor re-logs" do
      receive!(5)
      issue = build_issue(1)

      expect(approve(issue)).to be_ok
      expect(approve(issue)).not_to be_ok
      expect(reserved).to eq(1)
      expect(AuditLog.for_auditable(issue).where(action: "approve").count).to eq(1)
    end

    it "a repeated cancellation releases once" do
      receive!(5)
      issue = build_issue(1)
      approve(issue)

      expect(cancel(issue)).to be_ok
      expect(cancel(issue)).not_to be_ok
      expect(reserved).to eq(0)
      expect(AuditLog.for_auditable(issue).where(action: "cancel").count).to eq(1)
    end
  end

  describe "list-page availability flag" do
    it "flags pending/approved issues that couldn't be approved/confirmed now, with two queries" do
      receive!(1)
      holder = build_issue(1)
      approve(holder)
      blocked = build_issue(1)
      draft   = build_issue(9, status: :draft)

      issues = StockIssue.where(id: [ holder.id, blocked.id, draft.id ]).includes(:items).to_a
      ids = nil
      queries = 0
      counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        ids = Inventory::StockAvailability.unfulfillable_issue_ids(issues)
      end

      expect(ids).to contain_exactly(blocked.id)
      expect(queries).to eq(2)
    end
  end

  describe "concurrency" do
    self.use_transactional_tests = false

    after do
      ids = StockIssue.where(business: business).select(:id)
      AuditLog.where(business: business).delete_all
      InventoryMovement.where(business: business).delete_all
      StockIssueItem.where(stock_issue_id: ids).delete_all
      StockIssue.where(business: business).delete_all
      GoodsReceiptItem.where(goods_receipt_id: GoodsReceipt.where(business: business).select(:id)).delete_all
      GoodsReceipt.where(business: business).delete_all
      ProductBarcode.where(product_id: Product.where(business: business).select(:id)).delete_all
      Product.where(business: business).delete_all
      Warehouse.where(business: business).delete_all
      Branch.where(business: business).delete_all
      User.where(business: business).delete_all
      Business.where(id: business.id).delete_all
    end

    def race(items)
      gate    = Queue.new
      results = Queue.new
      threads = items.map do |item|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.pop
            results << yield(item)
          end
        end
      end
      items.size.times { gate << true }
      threads.each(&:join)
      Array.new(results.size) { results.pop }
    end

    it "never lets two concurrent approvals reserve the same final unit" do
      receive!(1)
      issues = [ build_issue(1), build_issue(1) ]
      # Hold each approval open after it reads availability, so without the
      # product lock both would read "1 available" before either commits.
      allow(Inventory::StockAvailability).to receive(:validate!).and_wrap_original do |original, *args|
        original.call(*args).tap { sleep 0.3 }
      end

      results = race(issues) { |issue| approve(issue) }

      expect(results.count(&:ok?)).to eq(1)
      expect(StockIssue.where(id: issues.map(&:id)).approved.count).to eq(1)
      expect(reserved).to eq(1)
    end

    it "never deducts twice for concurrent confirmations of the same issue" do
      receive!(2)
      issue = build_issue(1)
      approve(issue)

      results = race([ issue.id, issue.id ]) { |id| Inventory::StockIssueConfirmationService.new(stock_issue_id: id, actor: approver).call }

      expect(results.count(&:ok?)).to eq(1)
      expect(sugar.reload.current_stock).to eq(1)
      expect(InventoryMovement.where(source: issue).count).to eq(1)
    end
  end
end
