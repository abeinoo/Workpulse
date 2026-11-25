require "rails_helper"

# Stock Transfer approval workflow — lifecycle, Business Day and audit
# history (Inventory::StockTransferDraftService / Submission / Editor /
# Approval / Rejection / Cancellation).
RSpec.describe "Stock transfer workflow" do
  let(:business) { create(:business) }
  let!(:source)  { business.warehouses.create!(name: "Main") }
  let!(:dest)    { business.warehouses.create!(name: "Branch") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let!(:soap)    { business.products.create!(name: "Soap", sku: "SO-1", initial_cost_price: 4, average_cost_price: 4) }

  let(:all_transfer_permissions) { %i[view_stock_transfers create_stock_transfers approve_stock_transfers
                                      edit_pending_stock_transfers reject_stock_transfers cancel_stock_transfers] }
  let(:requester) { user_with_stock_permissions(business, :view_stock_transfers, :create_stock_transfers, name: "Requester") }
  let(:approver)  { user_with_stock_permissions(business, *all_transfer_permissions, name: "Approver") }
  let(:approver_with_dispatch) do
    user_with_stock_permissions(business, *all_transfer_permissions, :dispatch_stock_transfers, name: "Dispatcher")
  end

  def stock!(item, warehouse, qty)
    InventoryMovement.create!(business: business, product: item, warehouse: warehouse, direction: :in,
                              reason: :opening_balance, quantity: qty, unit_cost: item.average_cost_price,
                              occurred_on: Date.new(2026, 1, 1))
  end

  before do
    stock!(product, source, 100)
    stock!(soap, source, 20)
  end

  def attributes(lines = { product => 10 }, **header)
    { source_warehouse_id: source.id, destination_warehouse_id: dest.id, notes: "for the weekend",
      items_attributes: lines.each_with_index.to_h { |(item, qty), i| [ i.to_s, { product_id: item.id, quantity: qty } ] } }
      .merge(header)
  end

  def create_draft(actor = requester, lines = { product => 10 })
    result = Inventory::StockTransferDraftService.new(actor: actor, attributes: attributes(lines)).call
    expect(result).to be_ok, result.error
    result.transfer
  end

  def submit(transfer, actor = requester) = Inventory::StockTransferSubmission.new(stock_transfer_id: transfer.id, actor: actor).call
  def approve(transfer, actor = approver) = Inventory::StockTransferApproval.new(stock_transfer_id: transfer.id, actor: actor).call
  def reject(transfer, reason = "not needed", actor = approver)
    Inventory::StockTransferRejection.new(stock_transfer_id: transfer.id, actor: actor, reason: reason).call
  end
  def cancel(transfer, reason = "duplicate", actor = approver)
    Inventory::StockTransferCancellation.new(stock_transfer_id: transfer.id, actor: actor, reason: reason).call
  end

  def pending_transfer(lines = { product => 10 })
    create_draft(requester, lines).tap { |t| expect(submit(t)).to be_ok }
  end

  def transfer_movements = InventoryMovement.where(reason: %w[transfer_out transfer_in])
  def audit_entries(transfer) = AuditLog.for_auditable(transfer).order(:id)
  def available(item = product) = Inventory::StockAvailability.build_lines(
    warehouse_id: source.id, requested: { item.id => 0 }, products: { item.id => item }
  ).first.available

  describe "draft" do
    it "creates a draft with a reference and the current Business Day — no reservation, no movement" do
      transfer = nil
      expect { transfer = create_draft }.not_to change { transfer_movements.count }
      expect(transfer).to be_draft
      expect(transfer.transfer_number).to match(/\ATRF-\d{6}\z/)
      expect(transfer.transferred_on).to eq(BusinessDay.current(context: business))
      expect(transfer.created_by).to eq(requester)
      expect(available).to eq(100)
      expect(audit_entries(transfer).pluck(:action)).to eq(%w[create])
    end

    it "ignores a request date sent by the client" do
      result = Inventory::StockTransferDraftService.new(actor: requester,
                                                        attributes: attributes.merge(transferred_on: "2020-01-01")).call
      expect(result.transfer).to be_via_transit # every new transfer goes through transit (D1/D2)
      expect(result.transfer.transferred_on).to eq(BusinessDay.current(context: business))
    end

    it "edits a draft — lines, warehouses and notes — with a before/after audit entry" do
      transfer = create_draft
      line = transfer.items.first
      result = Inventory::StockTransferDraftService.new(
        stock_transfer_id: transfer.id, actor: requester, lock_token: transfer.lock_token,
        attributes: { notes: "changed", items_attributes: { "0" => { id: line.id, product_id: product.id, quantity: 12 } } }
      ).call
      expect(result).to be_ok
      expect(transfer.reload.items.sole.quantity).to eq(12)
      entry = audit_entries(transfer).last
      expect(entry.action).to eq("update")
      expect(entry.changes_json["items"]).to eq([ [ { "product_id" => product.id, "quantity" => "10" } ],
                                                  [ { "product_id" => product.id, "quantity" => "12" } ] ])
      expect(entry.changes_json["notes"]).to eq([ "for the weekend", "changed" ])
      expect(available).to eq(100)
    end

    it "refuses a stale edit" do
      transfer = create_draft
      result = Inventory::StockTransferDraftService.new(stock_transfer_id: transfer.id, actor: requester,
                                                        lock_token: "2000-01-01T00:00:00.000000Z", attributes: { notes: "x" }).call
      expect(result.error).to eq(I18n.t("inventory.stock_transfers.errors.stale_edit"))
    end

    it "refuses the same warehouse twice and an empty request" do
      same = Inventory::StockTransferDraftService.new(actor: requester, attributes: attributes(destination_warehouse_id: source.id)).call
      expect(same).not_to be_ok
      empty = Inventory::StockTransferDraftService.new(actor: requester, attributes: attributes({})).call
      expect(empty).not_to be_ok
      expect(StockTransfer.count).to eq(0)
    end
  end

  describe "submission" do
    it "reserves the requested quantities without moving stock, recording submitter, time and the original request" do
      transfer = create_draft(requester, { product => 40, soap => 5 })
      expect { expect(submit(transfer)).to be_ok }.not_to change { transfer_movements.count }

      transfer.reload
      expect(transfer).to be_pending_approval
      expect(transfer.submitted_by).to eq(requester)
      expect(transfer.submitted_at).to be_within(5.seconds).of(Time.current)
      expect(available(product)).to eq(60)
      expect(available(soap)).to eq(15)
      expect(product.stock_in(source)).to eq(100) # on hand unchanged

      entry = audit_entries(transfer).last
      expect(entry.action).to eq("submit_for_approval")
      expect(entry.actor).to eq(requester)
      expect(entry.metadata["requested_lines"]).to contain_exactly(
        { "product_id" => product.id, "quantity" => "40" }, { "product_id" => soap.id, "quantity" => "5" }
      )
      expect(transfer.items.pluck(:product_id, :requested_quantity)).to contain_exactly([ product.id, 40 ], [ soap.id, 5 ])
    end

    it "refuses insufficient stock and leaves the draft unchanged" do
      transfer = create_draft(requester, { product => 101 })
      result = submit(transfer)
      expect(result).not_to be_ok
      expect(result.error).to include("Not enough stock for Shampoo")
      expect(transfer.reload).to be_draft
      expect(transfer.submitted_at).to be_nil
      expect(available).to eq(100)
    end

    it "cannot submit twice" do
      transfer = pending_transfer
      expect(submit(transfer).error).to eq(I18n.t("inventory.stock_transfers.errors.invalid_transition"))
    end
  end

  describe "approval (via transit — a decision, no movement)" do
    it "moves to awaiting dispatch, keeps the reservation, posts nothing and records approver, time and quantities" do
      transfer = pending_transfer({ product => 30 })
      expect(transfer).to be_via_transit
      expect { expect(approve(transfer)).to be_ok }.not_to change { transfer_movements.count }

      transfer.reload
      expect(transfer).to be_awaiting_dispatch
      expect(transfer.approved_by).to eq(approver)
      expect(transfer.approved_at).to be_within(5.seconds).of(Time.current)
      expect(product.stock_in(source)).to eq(100)
      expect(available).to eq(70) # still reserved until dispatch

      entry = audit_entries(transfer).last
      expect(entry.action).to eq("approve")
      expect(entry.changes_json["status"]).to eq(%w[pending_approval awaiting_dispatch])
      expect(entry.metadata["approved_lines"]).to eq([ { "product_id" => product.id, "quantity" => "30", "unit_cost" => "0.0" } ])
    end

    it "allows self-approval by a requester who holds approve_stock_transfers" do
      transfer = create_draft(approver).tap { |t| expect(submit(t, approver)).to be_ok }
      expect(approve(transfer, approver)).to be_ok
      expect(audit_entries(transfer).last.metadata["self_approval"]).to be(true)
    end

    it "cannot approve twice" do
      transfer = pending_transfer
      expect(approve(transfer)).to be_ok
      expect(approve(transfer)).not_to be_ok
      expect(audit_entries(transfer).where(action: "approve").count).to eq(1)
    end

    it "approves the final edited quantities (the reservation follows them)" do
      transfer = pending_transfer({ product => 10 })
      line = transfer.items.first
      edit = Inventory::StockTransferEditor.new(stock_transfer_id: transfer.id, actor: approver, attributes: {
        items_attributes: { "0" => { id: line.id, quantity: 25 }, "1" => { product_id: soap.id, quantity: 3 } }
      }).call
      expect(edit).to be_ok
      expect(approve(transfer)).to be_ok
      expect(available(product)).to eq(75)
      expect(available(soap)).to eq(17)
    end

    it "re-validates availability under lock" do
      transfer = pending_transfer({ product => 60 })
      adjustment = business.stock_adjustments.build(warehouse: source, adjusted_on: Date.current, reason: "damaged")
      adjustment.items.build(product: product, quantity_difference: -40) # takes only unreserved stock
      adjuster = user_with_stock_permissions(business, :view_inventory, :manage_inventory, name: "Adjuster")
      expect(Inventory::AdjustmentPoster.new(adjustment, actor: adjuster).call).to be_ok
      expect(approve(transfer)).to be_ok # 60 on hand, 60 reserved by itself
      expect(available).to eq(0)
    end

    it "rolls back when the mandatory approval audit cannot be written" do
      transfer = pending_transfer
      allow_any_instance_of(Inventory::StockTransferApproval).to receive(:log_audit!).and_raise(AuditLoggable::AuditWriteFailed)
      expect(approve(transfer).error).to eq(I18n.t("inventory.stock_transfers.errors.audit_failed"))
      expect(transfer.reload).to be_pending_approval
    end
  end

  describe "approval of a DIRECT transfer (legacy semantics, D11)" do
    def direct_pending(qty = 30)
      t = business.stock_transfers.build(source_warehouse: source, destination_warehouse: dest, created_by: requester)
      t.items.build(product: product, quantity: qty)
      save_stock_transfer_in_status!(t, :pending_approval, actor: requester)
    end

    it "still posts source OUT and destination IN at once, on the approval Business Day" do
      transfer = travel_to(Time.zone.local(2026, 3, 1, 12)) { direct_pending }
      expect(transfer).to be_direct
      travel_to(Time.zone.local(2026, 3, 5, 12)) { expect(approve(transfer)).to be_ok }
      day = travel_to(Time.zone.local(2026, 3, 5, 12)) { BusinessDay.current(context: business) }
      transfer.reload
      expect(transfer).to be_approved
      expect(transfer.transferred_on).to eq(day)
      expect(product.stock_in(dest)).to eq(30)
      expect(transfer.inventory_movements.pluck(:reason)).to match_array(%w[transfer_out transfer_in])
      expect(audit_entries(transfer).last.metadata["movement_ids"]).to match_array(transfer.inventory_movements.ids)
    end

    it "rolls back everything when posting fails mid-way" do
      transfer = direct_pending(10)
      calls = 0
      allow_any_instance_of(Inventory::StockTransferPoster).to receive(:post_item).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::RecordInvalid, InventoryMovement.new if calls == 1
        original.call(*args)
      end
      expect(approve(transfer)).not_to be_ok
      expect(transfer.reload).to be_pending_approval
      expect(transfer_movements).to be_empty
    end
  end

  describe "rejection" do
    it "requires a reason" do
      transfer = pending_transfer
      expect(reject(transfer, "  ")).not_to be_ok
      expect(transfer.reload).to be_pending_approval
    end

    it "releases the reservation, moves nothing and records rejector, time and reason" do
      transfer = pending_transfer({ product => 40 })
      expect(available).to eq(60)
      expect { expect(reject(transfer, "wrong branch")).to be_ok }.not_to change { transfer_movements.count }
      transfer.reload
      expect(transfer).to be_rejected
      expect([ transfer.rejected_by, transfer.rejection_reason ]).to eq([ approver, "wrong branch" ])
      expect(transfer.rejected_at).to be_present
      expect(available).to eq(100)
      expect(audit_entries(transfer).last.metadata).to include("reason" => "wrong branch",
                                                               "reservation_released" => { product.id.to_s => "40" })
    end

    it "releases exactly once" do
      transfer = pending_transfer
      expect(reject(transfer)).to be_ok
      expect(reject(transfer)).not_to be_ok
      expect(audit_entries(transfer).where(action: "reject").count).to eq(1)
    end
  end

  describe "cancellation" do
    it "cancels a draft with a reason" do
      transfer = create_draft
      expect(cancel(transfer, "typo")).to be_ok
      expect(transfer.reload).to be_cancelled
      expect([ transfer.cancelled_by, transfer.cancellation_reason ]).to eq([ approver, "typo" ])
    end

    it "cancels a pending transfer, releasing its reservation" do
      transfer = pending_transfer({ product => 50 })
      expect(available).to eq(50)
      expect(cancel(transfer)).to be_ok
      expect(available).to eq(100)
      expect(audit_entries(transfer).last.metadata["reservation_released"]).to eq(product.id.to_s => "50")
    end

    it "requires a reason" do
      expect(cancel(create_draft, "")).not_to be_ok
    end

    it "cancels an approved transfer awaiting dispatch, releasing its reservation" do
      transfer = pending_transfer({ product => 20 }).tap { |t| expect(approve(t)).to be_ok }
      expect(available).to eq(80)
      expect(cancel(transfer)).to be_ok
      expect(transfer.reload).to be_cancelled
      expect(available).to eq(100)
    end

    it "refuses a dispatched transfer (D5) and a direct posted one (voided instead)" do
      transfer = pending_transfer.tap { |t| approve(t) }
      expect(Inventory::StockTransferDispatch.new(stock_transfer_id: transfer.id, actor: approver_with_dispatch).call).to be_ok
      expect(cancel(transfer).error).to eq(I18n.t("inventory.stock_transfers.errors.invalid_transition"))
      expect(transfer.reload).to be_in_transit

      direct = business.stock_transfers.build(source_warehouse: source, destination_warehouse: dest)
      direct.items.build(product: product, quantity: 1)
      direct = save_stock_transfer_in_status!(direct, :approved)
      expect(cancel(direct).error).to eq(I18n.t("inventory.stock_transfers.errors.invalid_transition"))
    end

    it "refuses a rejected or already cancelled transfer" do
      rejected = pending_transfer.tap { |t| reject(t) }
      cancelled = create_draft.tap { |t| cancel(t) }
      expect(cancel(rejected)).not_to be_ok
      expect(cancel(cancelled)).not_to be_ok
    end
  end

  describe "invalid transitions (model)" do
    it "allows only the workflow's transitions" do
      transfer = create_draft
      transfer.status = :approved
      expect(transfer).not_to be_valid
      expect(transfer.errors[:status]).to be_present
    end

    it "keeps decided transfers and their lines unchangeable, except the void" do
      transfer = business.stock_transfers.build(source_warehouse: source, destination_warehouse: dest)
      transfer.items.build(product: product, quantity: 5)
      transfer = save_stock_transfer_in_status!(transfer, :approved).reload
      expect(transfer.update(notes: "rewrite")).to be(false)
      expect(transfer.items.first.update(quantity: 1)).to be(false)
      expect(transfer.items.first.destroy).to be(false)
      transfer.reload # discard the refused in-memory changes
      expect(Inventory::DocumentVoider.new(transfer, user: create(:user, :owner, business: business), reason: "wrong").call).to be_ok
    end

    it "keeps the warehouses fixed once submitted" do
      transfer = pending_transfer
      result = Inventory::StockTransferEditor.new(stock_transfer_id: transfer.id, actor: approver,
                                                  attributes: { destination_warehouse_id: source.id }).call
      expect(result.error).to eq(I18n.t("inventory.stock_transfers.errors.warehouses_fixed"))
      transfer.reload.source_warehouse = dest
      expect(transfer).not_to be_valid
    end

    it "refuses to void a transfer that was never posted" do
      transfer = pending_transfer
      result = Inventory::DocumentVoider.new(transfer, user: create(:user, :owner, business: business), reason: "x").call
      expect(result).not_to be_ok
      expect(transfer.errors[:base].join).to include("Only a posted")
    end
  end

  describe "approver editing audit" do
    it "records before/after values and the reservation change, keeping the original request" do
      transfer = pending_transfer({ product => 10, soap => 5 })
      lines = transfer.items.index_by(&:product_id)
      result = Inventory::StockTransferEditor.new(stock_transfer_id: transfer.id, actor: approver, attributes: {
        notes: "approver note",
        items_attributes: { "0" => { id: lines[product.id].id, quantity: 4 }, "1" => { id: lines[soap.id].id, _destroy: "1" } }
      }).call
      expect(result).to be_ok

      entry = audit_entries(transfer).last
      expect(entry.action).to eq("update_pending")
      expect(entry.actor).to eq(approver)
      expect(entry.changes_json["items"].last).to eq([ { "product_id" => product.id, "quantity" => "4" } ])
      expect(entry.changes_json["notes"]).to eq([ "for the weekend", "approver note" ])
      expect(entry.metadata["reservation_change"]).to eq(product.id.to_s => %w[10 4], soap.id.to_s => %w[5 0])

      expect(transfer.items.reload.sole.requested_quantity).to eq(10) # the original request survives the edit (D9)
      original = audit_entries(transfer).find_by(action: "submit_for_approval")
      expect(original.metadata["requested_lines"]).to contain_exactly(
        { "product_id" => product.id, "quantity" => "10" }, { "product_id" => soap.id, "quantity" => "5" }
      )
      expect(transfer.reload).to be_pending_approval
    end
  end
end
