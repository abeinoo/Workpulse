require "rails_helper"

# Stock Transfer redesign, Phases B–D: approve -> dispatch (source -> system
# transit warehouse) -> receive (transit -> destination, partial allowed) ->
# discrepancy -> resolve (return to source / write off). The ledger stays the
# single source of stock: every leg is an InventoryMovement, totals and the
# moving average stay correct, and nothing is ever posted twice.
RSpec.describe "Stock transfer transit flow" do
  let(:business)  { create(:business) }
  let!(:source)   { business.warehouses.create!(name: "Main", kind: "central") }
  let!(:dest)     { business.warehouses.create!(name: "Annex") }
  let!(:product)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let!(:soap)     { business.products.create!(name: "Soap", sku: "SO-1", initial_cost_price: 4, average_cost_price: 4) }

  let(:all_permissions) do
    %i[view_stock_transfers create_stock_transfers approve_stock_transfers edit_pending_stock_transfers reject_stock_transfers
       cancel_stock_transfers dispatch_stock_transfers receive_stock_transfers resolve_stock_transfer_discrepancies]
  end
  let(:boss)       { user_with_stock_permissions(business, *all_permissions, name: "Boss") }
  let(:dispatcher) { user_with_stock_permissions(business, :view_stock_transfers, :dispatch_stock_transfers, name: "Dispatcher") }
  let(:receiver)   { user_with_stock_permissions(business, :view_stock_transfers, :receive_stock_transfers, name: "Receiver") }
  let(:resolver)   { user_with_stock_permissions(business, :view_stock_transfers, :resolve_stock_transfer_discrepancies, name: "Resolver") }

  before do
    [ [ product, 100, 10 ], [ soap, 20, 4 ] ].each do |item, qty, cost|
      InventoryMovement.create!(business: business, product: item, warehouse: source, direction: :in, reason: :opening_balance,
                                quantity: qty, unit_cost: cost, occurred_on: Date.new(2026, 1, 1))
    end
  end

  def approved(lines = { product => 30 })
    attrs = { source_warehouse_id: source.id, destination_warehouse_id: dest.id,
              items_attributes: lines.each_with_index.to_h { |(item, qty), i| [ i.to_s, { product_id: item.id, quantity: qty } ] } }
    t = Inventory::StockTransferDraftService.new(actor: boss, attributes: attrs).call.tap { |r| raise r.error unless r.ok? }.transfer
    raise "submit" unless Inventory::StockTransferSubmission.new(stock_transfer_id: t.id, actor: boss).call.ok?
    raise "approve" unless Inventory::StockTransferApproval.new(stock_transfer_id: t.id, actor: boss).call.ok?
    t.reload
  end

  def dispatch(transfer, actor = dispatcher) = Inventory::StockTransferDispatch.new(stock_transfer_id: transfer.id, actor: actor).call

  def in_transit(lines = { product => 30 }) = approved(lines).tap { |t| raise "dispatch" unless dispatch(t).ok? }.reload

  def receive_goods(transfer, quantities, actor: receiver, close: false, notes: nil)
    Inventory::StockTransferReceiving.new(stock_transfer_id: transfer.id, actor: actor, quantities: quantities,
                                          notes: notes, close_shortfall: close).call
  end

  def resolve(transfer, entries, reason: "Lost in delivery", actor: resolver)
    Inventory::StockTransferDiscrepancyResolution.new(stock_transfer_id: transfer.id, actor: actor, entries: entries, reason: reason).call
  end

  def item(transfer, product_record = product) = transfer.items.find_by!(product: product_record)
  def transit = Inventory::TransitWarehouse.find_for(business)
  def reserved(item_record = product) = Inventory::StockAvailability.reserved_by(warehouse_ids: source.id, product_ids: item_record.id)[[ source.id, item_record.id ]].to_d
  def transit_matches_outstanding!
    outstanding = StockTransfer.where(business: business).open_in_transit.flat_map do |t|
      Inventory::StockTransferProgress.for(t).lines.map { |l| [ l.item.product_id, l.remaining ] }
    end.group_by(&:first).transform_values { |pairs| pairs.sum(&:last) }
    [ product, soap ].each do |p|
      expect(p.stock_in(transit)).to eq(outstanding.fetch(p.id, 0)), "transit balance of #{p.name} vs outstanding transfers"
    end
  end

  describe "dispatch" do
    it "moves the stock source -> transit, consumes the reservation, keeps the business total and records who / when" do
      transfer = approved({ product => 30, soap => 5 })
      expect(reserved).to eq(30)
      travel_to(Time.zone.local(2026, 4, 2, 12)) { expect(dispatch(transfer)).to be_ok }

      transfer.reload
      day = travel_to(Time.zone.local(2026, 4, 2, 12)) { BusinessDay.current(context: business) }
      expect(transfer).to be_in_transit
      expect([ transfer.dispatched_by, transfer.dispatched_on, transfer.transferred_on ]).to eq([ dispatcher, day, day ])
      expect(transfer.dispatched_at).to be_present
      expect(transit).to be_transit
      expect(product.stock_in(source)).to eq(70)
      expect(product.stock_in(transit)).to eq(30)
      expect(product.stock_in(dest)).to eq(0)
      expect(product.current_stock).to eq(100) # nothing created or lost
      expect(reserved).to eq(0)                # consumed, not deducted twice
      expect(transfer.inventory_movements.pluck(:reason).tally).to eq("transfer_out" => 2, "transit_in" => 2)
      expect(transfer.inventory_movements.pluck(:occurred_on).uniq).to eq([ day ])
      expect(item(transfer).unit_cost).to eq(10)
      entry = AuditLog.where(auditable: transfer, action: "dispatch").sole
      expect(entry.metadata["movement_ids"]).to match_array(transfer.inventory_movements.ids)
      transit_matches_outstanding!
    end

    it "never changes the moving average" do
      transfer = approved
      expect { dispatch(transfer) }.not_to change { product.reload.average_cost_price }
    end

    it "cannot dispatch twice, nor before approval" do
      transfer = approved
      expect(dispatch(transfer)).to be_ok
      expect { expect(dispatch(transfer)).not_to be_ok }.not_to change(InventoryMovement, :count)

      pending = Inventory::StockTransferDraftService.new(actor: boss, attributes: {
        source_warehouse_id: source.id, destination_warehouse_id: dest.id, items_attributes: { "0" => { product_id: soap.id, quantity: 1 } }
      }).call.transfer
      expect(dispatch(pending)).not_to be_ok
    end

    it "is refused without the permission or without access to the SOURCE (destination access is not needed)" do
      transfer = approved
      expect(dispatch(transfer, receiver).error).to eq(I18n.t("inventory.stock_transfers.errors.not_permitted"))
      only_dest = user_with_stock_permissions(business, :view_stock_transfers, :dispatch_stock_transfers)
      WarehouseAssignment.create!(user: only_dest, warehouse: dest)
      expect(dispatch(transfer, only_dest).error).to eq(I18n.t("inventory.errors.warehouse_not_accessible"))
      only_source = user_with_stock_permissions(business, :view_stock_transfers, :dispatch_stock_transfers)
      WarehouseAssignment.create!(user: only_source, warehouse: source)
      expect(dispatch(transfer, only_source)).to be_ok
    end

    it "is atomic: a failure on any leg leaves no movement and keeps the reservation" do
      transfer = approved({ product => 10, soap => 2 })
      calls = 0
      allow(Inventory::StockTransferLedger).to receive(:leg!).and_wrap_original do |original, transfer_arg, **kw|
        calls += 1
        raise ActiveRecord::RecordInvalid, InventoryMovement.new if calls == 3
        original.call(transfer_arg, **kw)
      end
      expect(dispatch(transfer)).not_to be_ok
      expect(transfer.reload).to be_awaiting_dispatch
      expect(InventoryMovement.where(source: transfer)).to be_empty
      expect(reserved).to eq(10)
    end
  end

  describe "receiving" do
    it "receives in full: transit -> destination, completes the transfer, leaves nothing in transit" do
      transfer = in_transit
      expect(receive_goods(transfer, { item(transfer).id => 30 }, notes: "all good")).to be_ok
      transfer.reload
      expect(transfer).to be_received
      expect(transfer.received_at).to be_present
      expect(product.stock_in(dest)).to eq(30)
      expect(product.stock_in(transit)).to eq(0)
      expect(product.current_stock).to eq(100)
      receipt = transfer.receipts.sole
      expect([ receipt.received_by, receipt.notes, receipt.lines.sole.quantity ]).to eq([ receiver, "all good", 30 ])
      transit_matches_outstanding!
    end

    it "receives partially, more than once, never the same units twice" do
      transfer = in_transit
      line = item(transfer)
      expect(receive_goods(transfer, { line.id => 7 })).to be_ok
      expect(transfer.reload).to be_in_transit
      expect(transfer).to be_partially_received
      expect(Inventory::StockTransferProgress.for(transfer).by_item_id[line.id].remaining).to eq(23)
      transit_matches_outstanding!

      expect(receive_goods(transfer, { line.id => 24 }).error).to include("23")
      expect(receive_goods(transfer, { line.id => 23 })).to be_ok
      expect(transfer.reload).to be_received
      expect(product.stock_in(dest)).to eq(30)
      expect(receive_goods(transfer, { line.id => 1 })).not_to be_ok
      expect(transfer.receipts.count).to eq(2)
    end

    it "blocks excess (D4) and invalid quantities" do
      transfer = in_transit
      result = receive_goods(transfer, { item(transfer).id => 31 })
      expect(result.error).to include("Stock Adjustment")
      expect(receive_goods(transfer, { item(transfer).id => -1 })).not_to be_ok
      expect(receive_goods(transfer, { item(transfer).id => 0 }).error).to eq(I18n.t("inventory.stock_transfers.errors.nothing_to_receive"))
      expect(receive_goods(transfer, { 999_999 => 1 }).error).to eq(I18n.t("inventory.stock_transfers.errors.unknown_line"))
      expect(product.stock_in(dest)).to eq(0)
    end

    it "closes with a shortfall: the remainder stays in transit and the transfer awaits a resolution" do
      transfer = in_transit({ product => 10, soap => 4 })
      expect(receive_goods(transfer, { item(transfer).id => 7, item(transfer, soap).id => 4 }, close: true)).to be_ok
      transfer.reload
      expect(transfer).to be_discrepancy
      expect(product.stock_in(transit)).to eq(3)
      expect(soap.stock_in(transit)).to eq(0)
      expect(transfer.receipts.sole.closes_with_shortfall).to be(true)
      expect(receive_goods(transfer, { item(transfer).id => 3 })).not_to be_ok # no more receipts once closed
      transit_matches_outstanding!
    end

    it "is refused without the permission or without access to the DESTINATION" do
      transfer = in_transit
      expect(receive_goods(transfer, { item(transfer).id => 1 }, actor: dispatcher).error).to eq(I18n.t("inventory.stock_transfers.errors.not_permitted"))
      source_only = user_with_stock_permissions(business, :view_stock_transfers, :receive_stock_transfers)
      WarehouseAssignment.create!(user: source_only, warehouse: source)
      expect(receive_goods(transfer, { item(transfer).id => 1 }, actor: source_only).error).to eq(I18n.t("inventory.errors.warehouse_not_accessible"))
    end

    it "refuses incoming stock for a product Inactive at the destination" do
      transfer = in_transit
      ProductWarehouseSetting.create!(product: product, warehouse: dest, business: business, status: "inactive",
                                      status_reason: "closed", status_changed_at: Time.current)
      expect(receive_goods(transfer, { item(transfer).id => 5 })).not_to be_ok
      expect(product.stock_in(dest)).to eq(0)
    end

    it "receives at the line's dispatch cost and never changes the moving average" do
      transfer = in_transit
      expect { receive_goods(transfer, { item(transfer).id => 30 }) }.not_to change { product.reload.average_cost_price }
      expect(InventoryMovement.where(source: transfer, reason: "transfer_in").pluck(:unit_cost).uniq).to eq([ 10 ])
    end
  end

  describe "discrepancy resolution" do
    def short_transfer
      in_transit({ product => 10 }).tap { |t| receive_goods(t, { item(t).id => 6 }, close: true) }.reload
    end

    it "returns to source and writes off, with a reason, then completes the transfer" do
      transfer = short_transfer
      expect(product.stock_in(source)).to eq(90)
      expect(resolve(transfer, { item(transfer).id => { "return_to_source" => 3, "write_off" => 1 } })).to be_ok
      transfer.reload
      expect(transfer).to be_received
      expect(product.stock_in(source)).to eq(93)
      expect(product.stock_in(transit)).to eq(0)
      expect(product.stock_in(dest)).to eq(6)
      expect(product.current_stock).to eq(99) # only the written-off unit left the business
      expect(transfer.resolutions.pluck(:kind, :quantity, :reason))
        .to contain_exactly([ "return_to_source", 3, "Lost in delivery" ], [ "write_off", 1, "Lost in delivery" ])
      expect(InventoryMovement.where(source: transfer, reason: %w[transfer_return transfer_loss]).pluck(:reason, :warehouse_id))
        .to contain_exactly([ "transfer_return", source.id ], [ "transfer_loss", transit.id ])
      transit_matches_outstanding!
    end

    it "resolves in parts; never more than what is outstanding; nothing twice" do
      transfer = short_transfer
      line = item(transfer)
      expect(resolve(transfer, { line.id => { "write_off" => 5 } }).error).to include("4")
      expect(resolve(transfer, { line.id => { "write_off" => 1 } })).to be_ok
      expect(transfer.reload).to be_discrepancy
      expect(resolve(transfer, { line.id => { "return_to_source" => 3 } })).to be_ok
      expect(transfer.reload).to be_received
      expect(resolve(transfer, { line.id => { "write_off" => 1 } })).not_to be_ok
    end

    it "requires a reason and a discrepancy" do
      transfer = short_transfer
      expect(resolve(transfer, { item(transfer).id => { "write_off" => 1 } }, reason: " ").error)
        .to eq(I18n.t("inventory.stock_transfers.errors.resolution_reason_required"))
      open_transfer = in_transit
      expect(resolve(open_transfer, { item(open_transfer).id => { "write_off" => 1 } })).not_to be_ok
    end

    it "is refused without the permission or without access to both warehouses" do
      transfer = short_transfer
      expect(resolve(transfer, { item(transfer).id => { "write_off" => 1 } }, actor: receiver).error)
        .to eq(I18n.t("inventory.stock_transfers.errors.not_permitted"))
      one_side = user_with_stock_permissions(business, :view_stock_transfers, :resolve_stock_transfer_discrepancies)
      WarehouseAssignment.create!(user: one_side, warehouse: dest)
      expect(resolve(transfer, { item(transfer).id => { "write_off" => 1 } }, actor: one_side).error)
        .to eq(I18n.t("inventory.errors.warehouse_not_accessible"))
    end

    it "keeps receipts and resolutions append-only" do
      transfer = short_transfer
      resolve(transfer, { item(transfer).id => { "write_off" => 4 } })
      expect(transfer.receipts.first).to be_readonly
      expect { transfer.resolutions.first.update!(reason: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { StockTransferResolution.where(stock_transfer: transfer).update_all(reason: "x") }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end

  describe "history" do
    it "keeps the request, approved, dispatched and received quantities and a timeline from durable records" do
      transfer = in_transit({ product => 10 })
      receive_goods(transfer, { item(transfer).id => 4 })
      receive_goods(transfer, { item(transfer).id => 6 })
      transfer.reload
      expect(item(transfer).requested_quantity).to eq(10)
      logs = AuditLog.for_auditable(transfer).order(:created_at, :id).to_a
      events = Inventory::StockTransferTimeline.new(transfer, audit_logs: logs, receipts: transfer.receipts.to_a,
                                                              resolutions: transfer.resolutions.to_a).events.map(&:type)
      expect(events).to eq(%i[created submitted approved dispatched received_partially received_in_full])
    end

    it "cannot cancel or void after dispatch (D5)" do
      transfer = in_transit
      cancel = Inventory::StockTransferCancellation.new(stock_transfer_id: transfer.id, actor: boss, reason: "x").call
      expect(cancel).not_to be_ok
      void = Inventory::DocumentVoider.new(transfer, user: boss, reason: "x").call
      expect(void).not_to be_ok
      expect(transfer.reload).to be_in_transit
    end
  end
end
