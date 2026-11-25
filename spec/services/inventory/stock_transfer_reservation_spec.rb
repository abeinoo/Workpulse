require "rails_helper"

# Derived stock-transfer reservations (Inventory::StockAvailability): a
# PENDING transfer reserves its lines in the source warehouse; approved stock
# issues keep reserving exactly as before; every stock-consuming operation
# respects both through the one shared mechanism.
RSpec.describe "Stock transfer reservations" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:source)  { business.warehouses.create!(name: "Main") }
  let!(:dest)    { business.warehouses.create!(name: "Branch") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let!(:soap)    { business.products.create!(name: "Soap", sku: "SO-1", initial_cost_price: 4, average_cost_price: 4) }

  let(:requester) { user_with_stock_permissions(business, :view_stock_transfers, :create_stock_transfers, name: "Requester") }
  let(:approver)  do
    user_with_stock_permissions(business, :view_stock_transfers, :approve_stock_transfers, :edit_pending_stock_transfers,
                                :reject_stock_transfers, :cancel_stock_transfers, name: "Approver")
  end
  let(:issue_approver) { user_with_stock_permissions(business, :view_stock_issues, :approve_stock_issues, name: "Issue approver") }

  before do
    [ [ product, 100 ], [ soap, 20 ] ].each do |item, qty|
      InventoryMovement.create!(business: business, product: item, warehouse: source, direction: :in, reason: :opening_balance,
                                quantity: qty, unit_cost: item.average_cost_price, occurred_on: Date.new(2026, 1, 1))
    end
  end

  def draft(lines, from: source, to: dest)
    attributes = { source_warehouse_id: from.id, destination_warehouse_id: to.id,
                   items_attributes: lines.each_with_index.to_h { |(item, qty), i| [ i.to_s, { product_id: item.id, quantity: qty } ] } }
    Inventory::StockTransferDraftService.new(actor: requester, attributes: attributes).call.tap { |r| raise r.error unless r.ok? }.transfer
  end

  def submit(transfer) = Inventory::StockTransferSubmission.new(stock_transfer_id: transfer.id, actor: requester).call

  def pending(lines, **ends) = draft(lines, **ends).tap { |t| expect(submit(t)).to be_ok }

  def edit(transfer, items, **attrs)
    Inventory::StockTransferEditor.new(stock_transfer_id: transfer.id, actor: approver,
                                       attributes: attrs.merge(items_attributes: items)).call
  end

  def line_of(transfer, item) = transfer.items.reload.find { |l| l.product_id == item.id }

  def reserved(item = product, warehouse = source)
    Inventory::StockAvailability.reserved_by(warehouse_ids: warehouse.id, product_ids: item.id)[[ warehouse.id, item.id ]].to_d
  end

  def available(item = product, warehouse = source)
    item.stock_in(warehouse) - reserved(item, warehouse)
  end

  describe "the reservation formula" do
    it "a draft reserves nothing; a pending transfer reserves its lines in the SOURCE only" do
      transfer = draft({ product => 40 })
      expect(reserved).to eq(0)
      expect(submit(transfer)).to be_ok
      expect(reserved).to eq(40)
      expect(reserved(product, dest)).to eq(0)
      expect(available).to eq(60)
    end

    it "adds pending transfers to approved stock issue reservations" do
      issue = business.stock_issues.build(warehouse: source, issued_on: Date.current, created_by: owner)
      issue.items.build(product: product, quantity: 15)
      save_stock_issue_in_status!(issue, :approved)
      pending({ product => 25 })
      expect(reserved).to eq(40)
      expect(available).to eq(60)
    end

    it "excludes the transfer's own reservation when asked" do
      transfer = pending({ product => 40 })
      held = Inventory::StockAvailability.reserved_by(warehouse_ids: source.id, product_ids: product.id,
                                                      excluding_transfer_id: transfer.id)
      expect(held[[ source.id, product.id ]].to_d).to eq(0)
    end

    it "keeps reserving once approved (awaiting dispatch); releases on rejection / cancellation; dispatch consumes it" do
      rejected  = pending({ product => 10 })
      cancelled = pending({ product => 10 })
      approved  = pending({ product => 10 })
      expect(reserved).to eq(30)
      Inventory::StockTransferRejection.new(stock_transfer_id: rejected.id, actor: approver, reason: "no").call
      Inventory::StockTransferCancellation.new(stock_transfer_id: cancelled.id, actor: approver, reason: "no").call
      expect(reserved).to eq(10)
      expect(Inventory::StockTransferApproval.new(stock_transfer_id: approved.id, actor: owner).call).to be_ok
      expect(approved.reload).to be_awaiting_dispatch
      expect(reserved).to eq(10) # approval is a decision: still reserved
      expect(Inventory::StockTransferDispatch.new(stock_transfer_id: approved.id, actor: owner).call).to be_ok
      expect(reserved).to eq(0)
      expect(product.stock_in(source)).to eq(90) # deducted once, by the movement
      expect(product.current_stock).to eq(100)  # the rest is in transit, not lost
    end

    it "has no expiry: a pending transfer keeps its reservation indefinitely" do
      pending({ product => 30 })
      travel 400.days do
        expect(reserved).to eq(30)
      end
    end
  end

  describe "multiple pending transfers (spec §7 example)" do
    it "A 40 + B 30 leave 30 available, so C 40 cannot enter Pending Approval" do
      pending({ product => 40 })
      pending({ product => 30 })
      expect(available).to eq(30)

      c = draft({ product => 40 })
      result = submit(c)
      expect(result).not_to be_ok
      expect(result.error).to include("Available: 30, requested: 40")
      expect(result.error).to match(/pending stock transfers TRF-\d+, TRF-\d+/)
      expect(c.reload).to be_draft
      expect(available).to eq(30)

      exact = draft({ product => 30 })
      expect(submit(exact)).to be_ok
      expect(available).to eq(0)
    end

    it "two pending transfers that together fit both approve and dispatch, each consuming only its own reservation" do
      a = pending({ product => 60 })
      b = pending({ product => 40 })
      [ a, b ].each do |t|
        expect(Inventory::StockTransferApproval.new(stock_transfer_id: t.id, actor: owner).call).to be_ok
      end
      expect(available).to eq(0) # both still reserved, awaiting dispatch
      [ a, b ].each do |t|
        expect(Inventory::StockTransferDispatch.new(stock_transfer_id: t.id, actor: owner).call).to be_ok
      end
      expect(product.stock_in(source)).to eq(0)
      expect(available).to eq(0)
    end

    it "an approved transfer awaiting dispatch still blocks other documents from its stock" do
      a = pending({ product => 80 })
      expect(Inventory::StockTransferApproval.new(stock_transfer_id: a.id, actor: owner).call).to be_ok
      result = submit(draft({ product => 30 }))
      expect(result).not_to be_ok
      expect(result.error).to include("Available: 20, requested: 30")
    end
  end

  describe "approver edits update the reservation atomically" do
    it "increasing reserves the extra; decreasing releases the difference" do
      transfer = pending({ product => 40 })
      expect(edit(transfer, { "0" => { id: line_of(transfer, product).id, quantity: 70 } })).to be_ok
      expect(reserved).to eq(70)
      expect(edit(transfer, { "0" => { id: line_of(transfer, product).id, quantity: 5 } })).to be_ok
      expect(reserved).to eq(5)
      expect(transfer.reload).to be_pending_approval
    end

    it "adding a product reserves it; removing a product releases it" do
      transfer = pending({ product => 10 })
      expect(edit(transfer, { "0" => { product_id: soap.id, quantity: 8 } })).to be_ok
      expect(reserved(soap)).to eq(8)
      expect(edit(transfer, { "0" => { id: line_of(transfer, soap).id, _destroy: "1" } })).to be_ok
      expect(reserved(soap)).to eq(0)
      expect(reserved(product)).to eq(10)
    end

    it "an increase beyond availability rejects the WHOLE edit and keeps the previous reservation" do
      pending({ product => 50 })
      transfer = pending({ product => 30, soap => 5 })
      result = edit(transfer, { "0" => { id: line_of(transfer, product).id, quantity: 60 },
                                "1" => { id: line_of(transfer, soap).id, quantity: 1 } }, notes: "changed")
      expect(result).not_to be_ok
      expect(result.error).to include("Available: 50, requested: 60") # own 30 excluded, 50 held by the other
      transfer.reload
      expect(transfer.items.map { |i| [ i.product_id, i.quantity ] }).to contain_exactly([ product.id, 30 ], [ soap.id, 5 ])
      expect(transfer.notes).to be_nil
      expect(reserved).to eq(80)
      expect(reserved(soap)).to eq(5)
      expect(AuditLog.for_auditable(transfer).where(action: "update_pending")).to be_empty
    end

    it "a reservation never competes with itself: keeping all 100 reserved and adding notes is fine" do
      transfer = pending({ product => 100 })
      expect(edit(transfer, {}, notes: "ok")).to be_ok
      expect(reserved).to eq(100)
    end
  end

  describe "Stock Issue compatibility" do
    def issue(qty, status = :pending_approval)
      i = business.stock_issues.build(warehouse: source, issued_on: Date.current, created_by: owner)
      i.items.build(product: product, quantity: qty)
      save_stock_issue_in_status!(i, status)
    end

    it "a pending stock issue still reserves nothing" do
      issue(30)
      expect(reserved).to eq(0)
    end

    it "an approved stock issue still reserves, and a transfer cannot take its stock" do
      issue(70, :approved)
      expect(reserved).to eq(70)
      result = submit(draft({ product => 31 }))
      expect(result).not_to be_ok
      expect(result.error).to match(/approved stock issues ISS-\d+/)
    end

    it "an issue cannot be approved against stock a pending transfer holds — the message names the transfer" do
      pending({ product => 90 })
      pending_issue = issue(20)
      result = Inventory::StockIssueApproval.new(stock_issue_id: pending_issue.id, actor: issue_approver).approve!
      expect(result).not_to be_ok
      expect(result.error).to include("Available to issue: 10, requested: 20")
      expect(result.error).to match(/pending stock transfers TRF-\d+/)
      expect(pending_issue.reload).to be_pending_approval
    end

    it "an issue that fits beside the pending transfer is approved and confirmed normally" do
      pending({ product => 90 })
      fitting = issue(10)
      expect(Inventory::StockIssueApproval.new(stock_issue_id: fitting.id, actor: issue_approver).approve!).to be_ok
      expect(Inventory::StockIssuePoster.new(fitting.reload).call).to be_ok
      expect(product.stock_in(source)).to eq(90)
      expect(reserved).to eq(90)
    end

    it "keeps the issue-only message unchanged when no transfer holds the stock" do
      issue(100, :approved)
      other = issue(1)
      result = Inventory::StockIssueApproval.new(stock_issue_id: other.id, actor: issue_approver).approve!
      expect(result.error).to include("Other approved stock issues have already reserved 100 of the 100 on hand")
    end
  end

  describe "other stock-consuming operations respect pending transfer reservations" do
    before { pending({ product => 90 }) }

    it "a stock adjustment cannot remove reserved stock" do
      adjustment = business.stock_adjustments.build(warehouse: source, adjusted_on: Date.current, reason: "damaged", created_by: owner)
      adjustment.items.build(product: product, quantity_difference: -20)
      result = Inventory::AdjustmentPoster.new(adjustment, actor: owner).call
      expect(result).not_to be_ok
      expect(adjustment.errors[:base].join).to match(/reserved by pending stock transfers TRF-\d+/)
      expect(product.stock_in(source)).to eq(100)
    end

    it "an adjustment within the unreserved stock posts" do
      adjustment = business.stock_adjustments.build(warehouse: source, adjusted_on: Date.current, reason: "damaged", created_by: owner)
      adjustment.items.build(product: product, quantity_difference: -10)
      expect(Inventory::AdjustmentPoster.new(adjustment, actor: owner).call).to be_ok
      expect(available).to eq(0)
    end

    it "stock-count approval cannot shrink stock below the reservation" do
      counter = user_with_stock_permissions(business, :view_inventory, :manage_stock_counts, name: "Counter")
      count = record_stock_count!(business: business, warehouse: source, counter: counter,
                                  lines: [ [ product, 50 ], [ soap, 20 ] ], complete: true)
      result = approve_stock_count(count, owner)
      expect(result).not_to be_ok
      expect(product.stock_in(source)).to eq(100)
    end

    it "laundry consumption cannot use reserved stock" do
      branch = create(:branch, business: business, branch_type: "laundry")
      batch  = Laundry::LaundryBatchService.create(actor: owner, laundry_branch_id: branch.id,
                                                   towel_type_id: business.towel_types.create!(name: "Bath").id).batch
      result = Laundry::BatchMaterialConsumer.new(batch, source).call(product: product, quantity: 11)
      expect(result).not_to be_ok
      expect(result.error).to match(/pending stock transfers TRF-\d+/)
      expect(product.stock_in(source)).to eq(100)
    end

    it "a void (of a direct posted transfer) cannot pull back stock a pending transfer reserves in the destination" do
      inbound = business.stock_transfers.build(source_warehouse: source, destination_warehouse: dest)
      inbound.items.build(product: soap, quantity: 20)
      inbound = save_stock_transfer_in_status!(inbound, :approved) # direct: posted source -> destination
      onward = pending({ soap => 15 }, from: dest, to: source)
      result = Inventory::DocumentVoider.new(inbound.reload, user: owner, reason: "wrong").call
      expect(result).not_to be_ok
      expect(inbound.errors[:base].join).to include(onward.transfer_number)
      expect(soap.stock_in(dest)).to eq(20)
    end
  end
end
