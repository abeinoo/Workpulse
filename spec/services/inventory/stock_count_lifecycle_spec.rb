require "rails_helper"

# The stock count lifecycle services end to end:
#   Creator → Recorder → Completion → Approver → Reopener → (Approver again)
#   Removal (delete / cancel)
# Covers decisions D2 (per-product count time + baseline), D3 (reopen reverses
# through compensating movements), D4 (delete vs cancel), D6 (audit trail) and
# D7–D9 (legacy, unverified quantities).
RSpec.describe "Stock count lifecycle", type: :model do
  let(:business)  { create(:business) }
  let(:counter)   { user_with_stock_permissions(business, :view_inventory, :manage_stock_counts) }
  let(:approver)  { user_with_stock_permissions(business, :view_inventory, :post_stock_counts) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:other_warehouse) { business.warehouses.create!(name: "Annex") }
  let(:shampoo)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 3, average_cost_price: 3) }
  let(:wax)       { business.products.create!(name: "Wax", sku: "WX-1", initial_cost_price: 2, average_cost_price: 2) }
  let(:branch)    { business.branches.create!(name: "Branch", active: true) }

  def receive!(product, qty, into: warehouse)
    r = business.goods_receipts.build(warehouse: into, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: product.average_cost_price)
    expect(Inventory::GoodsReceiptPoster.new(r).call.ok?).to be(true)
  end

  def issue!(product, qty)
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    i.items.build(product: product, quantity: qty)
    expect(approve_and_post_stock_issue(i).ok?).to be(true)
  end

  def actions_for(record) = AuditLog.for_auditable(record).order(:id).pluck(:action)

  # A pre-upgrade count: quantities entered with no source and no count time.
  def legacy_count(status: :in_progress, lines:)
    count = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: counter,
                                        status: status, started_at: 2.days.ago)
    lines.each { |product, system, counted| count.items.build(product: product, system_quantity: system, counted_quantity: counted) }
    count.save!
    count
  end

  before do
    receive!(shampoo, 12)
    receive!(wax, 7)
  end

  describe "creation and counting" do
    it "creates a draft with every product preloaded and audits it" do
      result = Inventory::StockCountCreator.new(actor: counter, warehouse_id: warehouse.id, counted_on: Date.current).call
      count  = result.count
      expect(result.ok?).to be(true)
      expect(count).to be_draft
      expect(count.items.map { |i| [ i.product_id, i.system_quantity ] }).to contain_exactly([ shampoo.id, 12 ], [ wax.id, 7 ])
      expect(count.items).to all(have_attributes(counted_quantity: nil, quantity_source: nil))
      expect(actions_for(count)).to eq(%w[create])
    end

    it "refuses another business's warehouse without reading its stock" do
      foreign = create(:business).warehouses.create!(name: "Theirs")
      result  = Inventory::StockCountCreator.new(actor: counter, warehouse_id: foreign.id, counted_on: Date.current).call
      expect(result.ok?).to be(false)
      expect(StockCount.count).to eq(0)
    end

    it "records each physical count with its own time and the ledger quantity at that moment (D2)" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      travel_to(2.hours.from_now) { record_counts!(count, counter, [ [ shampoo, 10 ] ]) }
      receive!(wax, 3)                                   # wax now 10
      travel_to(3.hours.from_now) { record_counts!(count, counter, [ [ wax, 9 ] ]) }

      items = count.reload.items.index_by(&:product_id)
      expect(count).to be_in_progress
      expect(items[shampoo.id]).to have_attributes(counted_quantity: 10, system_quantity: 12, difference: -2,
                                                   quantity_source: "physical")
      expect(items[wax.id]).to have_attributes(counted_quantity: 9, system_quantity: 10, difference: -1)
      expect(items[shampoo.id].counted_at).to be < items[wax.id].counted_at
      expect(items[shampoo.id].baseline_at).to eq(items[shampoo.id].counted_at)
      expect(actions_for(count)).to eq(%w[create start_counting record_counts record_counts])
    end

    it "keeps a quantity's original count time when it is re-submitted unchanged" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ])
      first = count.items.find_by(product: shampoo).counted_at
      travel_to(1.hour.from_now) { record_counts!(count, counter, [ [ shampoo, 10 ] ]) }
      expect(count.items.find_by(product: shampoo).counted_at).to eq(first)
    end

    it "ignores a client-supplied system quantity and clears a row left blank" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ])
      item  = count.items.find_by(product: shampoo)
      Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: counter,
                                        entries: [ { id: item.id, counted_quantity: "", system_quantity: "999" } ]).call
      expect(item.reload).to have_attributes(counted_quantity: nil, counted_at: nil, quantity_source: nil, system_quantity: 12)
    end

    it "rejects an unparseable quantity and a row of another count, writing nothing" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      other = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      bad   = Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: counter,
                                                entries: [ { product_id: shampoo.id, counted_quantity: "abc" } ]).call
      alien = Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: counter,
                                                entries: [ { id: other.items.first.id, counted_quantity: "1" } ]).call
      expect([ bad.ok?, alien.ok? ]).to eq([ false, false ])
      expect(count.reload).to be_draft
      expect(count.items.where.not(counted_quantity: nil)).to be_empty
    end

    it "refuses counts once submitted" do
      count  = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ], complete: true)
      result = Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: counter,
                                                 entries: [ { product_id: shampoo.id, counted_quantity: "1" } ]).call
      expect(result.error).to eq(I18n.t("inventory.stock_counts.errors.not_editable"))
      expect(count.reload.items.find_by(product: shampoo).counted_quantity).to eq(10)
    end
  end

  describe "completion (D1: no stock change)" do
    it "submits for approval without posting any movement" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ])
      expect { complete_stock_count!(count, counter) }.not_to change(InventoryMovement, :count)
      expect(count).to have_attributes(status: "completed", completed_by_id: counter.id)
      expect(shampoo.stock_in(warehouse)).to eq(12)
      expect(actions_for(count).last).to eq("complete")
    end

    it "refuses a draft and a repeated completion" do
      draft = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      expect(Inventory::StockCountCompletion.new(stock_count_id: draft.id, actor: counter).call.ok?).to be(false)

      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ], complete: true)
      expect(Inventory::StockCountCompletion.new(stock_count_id: count.id, actor: counter).call.ok?).to be(false)
      expect(actions_for(count).count("complete")).to eq(1)
    end
  end

  describe "legacy incomplete counts (D7–D9)" do
    # The decision D9 example: Shampoo old 8, recounted 10; Wax old 5, not recounted.
    let(:count) { legacy_count(lines: [ [ shampoo, 6, 8 ], [ wax, 4, 5 ] ]) }

    it "keeps old quantities as unverified history, never as physical counts" do
      items = count.items.index_by(&:product_id)
      expect(items.values).to all(be_legacy_unverified)
      expect(count.legacy_items.size).to eq(2)
      expect(count).to be_editable_counts
    end

    it "a blank entry leaves the legacy quantity untouched; a new entry is a physical recount" do
      shampoo_item = count.items.find_by(product: shampoo)
      wax_item     = count.items.find_by(product: wax)
      Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: counter, entries: [
        { id: shampoo_item.id, counted_quantity: "10" }, { id: wax_item.id, counted_quantity: "" }
      ]).call

      expect(shampoo_item.reload).to have_attributes(counted_quantity: 10, legacy_counted_quantity: 8,
                                                     quantity_source: "physical", system_quantity: 12)
      expect(shampoo_item.counted_at).to be_present
      expect(wax_item.reload).to have_attributes(counted_quantity: 5, legacy_counted_quantity: nil, quantity_source: nil)
    end

    it "on completion adopts the system quantity for products not recounted, with no artificial difference" do
      record_counts!(count, counter, [ [ shampoo, 10 ] ])
      complete_stock_count!(count, counter)

      items = count.reload.items.index_by(&:product_id)
      expect(items[shampoo.id]).to have_attributes(counted_quantity: 10, quantity_source: "physical", legacy_counted_quantity: 8)
      expect(items[wax.id]).to have_attributes(counted_quantity: 7, system_quantity: 7, difference: 0,
                                               quantity_source: "system", legacy_counted_quantity: 5, counted_at: nil)
      expect(items[wax.id].baseline_at).to eq(count.completed_at)
      entry = AuditLog.for_auditable(count).find_by!(action: "complete")
      expect(entry.metadata["system_adopted"]).to eq([ { "product_id" => wax.id, "legacy_quantity" => "5", "adopted_quantity" => "7" } ])
    end

    it "is completed without forcing a recount of every product, and approves to the right balances" do
      record_counts!(count, counter, [ [ shampoo, 10 ] ])
      complete_stock_count!(count, counter)
      receive!(wax, 4)                     # after the cutoff: preserved
      expect(approve_stock_count(count, approver).ok?).to be(true)

      adjustment = count.reload.active_stock_adjustment
      expect(adjustment.items.map { |i| [ i.product_id, i.quantity_difference ] }).to eq([ [ shampoo.id, -2 ] ])
      expect([ shampoo.stock_in(warehouse), wax.stock_in(warehouse) ]).to eq([ 10, 11 ])
    end

    it "keeps a legacy draft usable" do
      draft = legacy_count(status: :draft, lines: [ [ shampoo, 12, nil ] ])
      record_counts!(draft, counter, [ [ shampoo, 11 ] ])
      expect(draft).to be_in_progress
      complete_stock_count!(draft, counter)
      expect(approve_stock_count(draft, approver).ok?).to be(true)
      expect(shampoo.stock_in(warehouse)).to eq(11)
    end
  end

  describe "reopening an approved count (D3)" do
    let(:count) do
      record_stock_count!(business: business, warehouse: warehouse, counter: counter,
                          lines: [ [ shampoo, 10 ], [ wax, 9 ] ], complete: true)   # −2 / +2
    end

    before { expect(approve_stock_count(count, approver).ok?).to be(true) }

    it "reverses the adjustment with compensating movements and returns to counting" do
      original = count.reload.active_stock_adjustment
      result   = reopen_stock_count(count, approver, reason: "Miscounted the back shelf")

      expect(result.ok?).to be(true)
      expect(count.reload).to have_attributes(status: "in_progress", approved_at: nil, completed_at: nil)
      expect(original.reload).to be_voided
      expect(original.void_reason).to eq("Miscounted the back shelf")
      expect(original.inventory_movements.where(reason: "adjustment").count).to eq(2)   # originals kept
      expect(original.inventory_movements.where(reason: "reversal").pluck(:product_id, :direction, :quantity))
        .to contain_exactly([ shampoo.id, "in", 2 ], [ wax.id, "out", 2 ])
      expect([ shampoo.stock_in(warehouse), wax.stock_in(warehouse) ]).to eq([ 12, 7 ])
      expect(count.items.find_by(product: shampoo).counted_quantity).to eq(10)          # kept for editing
      expect(actions_for(count).last).to eq("reopen")
      expect(actions_for(original)).to eq(%w[post void])
    end

    it "preserves movements posted after the approval (no snapshot restore)" do
      receive!(shampoo, 5)                               # 10 → 15
      reopen_stock_count(count, approver)
      expect(shampoo.stock_in(warehouse)).to eq(17)      # 15 + 2 reversed
    end

    it "re-approval posts a new adjustment from the edited counts; history keeps both" do
      reopen_stock_count(count, approver)
      record_counts!(count, counter, [ [ shampoo, 9 ] ])  # recounted now against 12 → −3
      complete_stock_count!(count, counter)
      expect(approve_stock_count(count, approver).ok?).to be(true)

      expect(count.reload.stock_adjustments.count).to eq(2)
      expect(count.stock_adjustments.active.count).to eq(1)
      expect(count.active_stock_adjustment.items.map { |i| [ i.product_id, i.quantity_difference ] })
        .to contain_exactly([ shampoo.id, -3 ], [ wax.id, 2 ])
      expect([ shampoo.stock_in(warehouse), wax.stock_in(warehouse) ]).to eq([ 9, 9 ])
      expect(actions_for(count)).to include("approve", "reopen")
      expect(actions_for(count).count("approve")).to eq(2)
    end

    it "is refused, changing nothing, when the reversal would oversell" do
      issue!(wax, 9)                                     # the +2 overage has been issued out
      result = nil
      expect { result = reopen_stock_count(count, approver) }.not_to change(InventoryMovement, :count)
      expect(result.ok?).to be(false)
      expect(result.error).to match(/reversing needs/i)
      expect(count.reload).to be_approved
      expect(count.active_stock_adjustment).not_to be_voided
    end

    it "requires a reason" do
      result = reopen_stock_count(count, approver, reason: " ")
      expect(result.error).to eq(I18n.t("inventory.stock_counts.errors.reopen_reason_required"))
      expect(count.reload).to be_approved
    end

    it "never reverses twice (a repeated reopen is refused)" do
      expect(reopen_stock_count(count, approver).ok?).to be(true)
      expect(reopen_stock_count(count, approver).ok?).to be(false)
      expect(InventoryMovement.where(reason: "reversal").count).to eq(2)
      expect([ shampoo.stock_in(warehouse), wax.stock_in(warehouse) ]).to eq([ 12, 7 ])
    end

    it "can be reopened and re-approved repeatedly with exactly one active effect" do
      2.times do
        reopen_stock_count(count, approver)
        complete_stock_count!(count, counter)
        expect(approve_stock_count(count, approver).ok?).to be(true)
      end
      expect(count.reload.stock_adjustments.count).to eq(3)
      expect(count.stock_adjustments.active.count).to eq(1)
      expect([ shampoo.stock_in(warehouse), wax.stock_in(warehouse) ]).to eq([ 10, 9 ])
    end

    it "blocks voiding the count's adjustment on its own" do
      adjustment = count.reload.active_stock_adjustment
      result = Inventory::DocumentVoider.new(adjustment, user: approver, reason: "x").call
      expect(result.ok?).to be(false)
      expect(adjustment.reload).not_to be_voided
    end
  end

  describe "reopening a pre-repair approved count" do
    def legacy_approved(adjustment_link:)
      count = legacy_count(status: :in_progress, lines: [ [ shampoo, 12, 10 ] ])
      adjustment = StockAdjustment.new(business: business, warehouse: warehouse, adjusted_on: Date.current,
                                       reason: "stock_count", adjustment_number: "ADJ-LEGACY", created_by: approver,
                                       stock_count_id: (count.id if adjustment_link))
      adjustment.items.build(product: shampoo, quantity_difference: -2, unit_cost: 3)
      adjustment.save!(validate: false)
      count.update_columns(status: "approved", approved_at: 1.day.ago, stock_adjustment_id: adjustment.id)
      [ count.reload, adjustment ]
    end

    it "is refused when its adjustment was never linked, so it can't be applied twice" do
      count, adjustment = legacy_approved(adjustment_link: false)
      result = reopen_stock_count(count, approver)
      expect(result.error).to eq(I18n.t("inventory.stock_counts.errors.legacy_link_unresolved"))
      expect(count.reload).to be_approved
      expect(adjustment.reload).not_to be_voided
    end

    it "reverses a backfilled (linked) adjustment like any other" do
      count, adjustment = legacy_approved(adjustment_link: true)
      expect(reopen_stock_count(count, approver).ok?).to be(true)
      expect(adjustment.reload).to be_voided
    end
  end

  describe "reopening a completed count" do
    it "returns it to counting without touching stock or requiring a reason" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ], complete: true)
      expect { expect(reopen_stock_count(count, approver, reason: nil).ok?).to be(true) }.not_to change(InventoryMovement, :count)
      expect(count.reload).to have_attributes(status: "in_progress", completed_at: nil, completed_by_id: nil)
    end

    it "refuses a draft" do
      draft = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      expect(reopen_stock_count(draft, approver).error).to eq(I18n.t("inventory.stock_counts.errors.not_reopenable"))
    end
  end

  describe "delete vs cancel (D4)" do
    def removal(count, reason: "Started by mistake") =
      Inventory::StockCountRemoval.new(stock_count_id: count.id, actor: counter, reason: reason)

    it "hard-deletes a draft, audited with a snapshot" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      expect(removal(count).delete!.ok?).to be(true)
      expect(StockCount.exists?(count.id)).to be(false)
      expect(StockCountItem.where(stock_count_id: count.id)).to be_empty
      entry = AuditLog.find_by!(auditable_type: "StockCount", auditable_id: count.id, action: "delete")
      expect(entry.metadata).to include("count_number" => count.count_number, "reason" => "Started by mistake", "status" => "draft")
    end

    it "hard-deletes an in-progress count, and a reopened count that never posted" do
      in_progress = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 3 ] ])
      reopened = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 3 ] ], complete: true)
      reopen_stock_count(reopened, approver)

      expect { [ in_progress, reopened ].each { |c| expect(removal(c).delete!.ok?).to be(true) } }
        .not_to change(InventoryMovement, :count)
      expect(StockCount.where(id: [ in_progress.id, reopened.id ])).to be_empty
      expect(AuditLog.where(auditable_type: "StockCount", action: "delete").count).to eq(2)
    end

    it "never hard-deletes a count that once posted stock; it is cancelled instead, preserving history" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ], complete: true)
      approve_stock_count(count, approver)
      reopen_stock_count(count, approver)

      expect(count.reload).not_to be_deletable
      expect(removal(count).delete!.error).to eq(I18n.t("inventory.stock_counts.errors.not_deletable"))
      expect(StockCount.exists?(count.id)).to be(true)

      result = removal(count, reason: "Superseded by SC recount").cancel!
      expect(result.ok?).to be(true)
      expect(count.reload).to have_attributes(status: "cancelled", cancelled_by_id: counter.id, cancel_reason: "Superseded by SC recount")
      expect(count.stock_adjustments.count).to eq(1)       # the voided adjustment keeps pointing at it
      expect(shampoo.stock_in(warehouse)).to eq(12)        # reversal stands; cancel changes nothing
      expect(actions_for(count).last).to eq("cancel")
      expect(count.update(notes: "tamper")).to be(false)   # cancelled is terminal
    end

    it "refuses to delete or cancel completed and approved counts" do
      completed = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ], complete: true)
      approved  = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ wax, 7 ] ], complete: true)
      approve_stock_count(approved, approver)

      [ completed, approved ].each do |c|
        expect(removal(c).delete!.ok?).to be(false)
        expect(removal(c).cancel!.ok?).to be(false)
      end
      expect(StockCount.where(id: [ completed.id, approved.id ]).count).to eq(2)
      expect { approved.reload.destroy }.to raise_error(ImmutableDocument::DeletionNotAllowedError)
    end

    it "refuses to cancel a count that never posted (delete it instead)" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 3 ] ])
      expect(removal(count).cancel!.error).to eq(I18n.t("inventory.stock_counts.errors.not_cancellable"))
    end

    it "requires a reason" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      expect(removal(count, reason: "").delete!.error).to eq(I18n.t("inventory.stock_counts.errors.removal_reason_required"))
      expect(StockCount.exists?(count.id)).to be(true)
    end

    it "a repeated delete is refused cleanly" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      removal(count).delete!
      expect { removal(count).delete! }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "audit trail (D6)" do
    it "records every transition with actor, time and status change, inside the operation's transaction" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ], complete: true)
      approve_stock_count(count, approver)
      reopen_stock_count(count, approver, reason: "Recount")

      entries = AuditLog.for_auditable(count).order(:id)
      expect(entries.map(&:action)).to eq(%w[create start_counting record_counts complete approve reopen])
      expect(entries.map(&:actor_id)).to eq([ counter.id ] * 4 + [ approver.id ] * 2)
      expect(entries.find_by(action: "approve").changes_json).to eq("status" => %w[completed approved])
      expect(entries.find_by(action: "reopen").metadata).to include("reason" => "Recount", "reversed_adjustment_number" => count.stock_adjustments.first.adjustment_number)
      record = entries.find_by(action: "record_counts").metadata["items"].sole
      expect(record).to include("product_id" => shampoo.id, "from" => nil, "to" => "10", "system_quantity" => "12")
    end

    it "exposes no application route that edits or deletes audit entries" do
      writable = Rails.application.routes.routes.select do |route|
        route.defaults[:controller].to_s.match?(/audit/) && route.verb.match?(/PATCH|PUT|DELETE|POST/)
      end
      expect(writable).to be_empty
    end

    it "rolls back the transition when a fail-closed audit entry cannot be written" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ])
      allow(AuditLog).to receive(:create!).and_wrap_original do |original, **attrs|
        raise ActiveRecord::StatementInvalid, "boom" if attrs[:action] == "complete"

        original.call(**attrs)
      end
      result = Inventory::StockCountCompletion.new(stock_count_id: count.id, actor: counter).call
      expect(result.error).to eq(I18n.t("inventory.stock_counts.errors.audit_failed"))
      expect(count.reload).to be_in_progress
    end
  end

  describe "isolation" do
    it "never loads another business's count" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ], complete: true)
      outsider = create(:user, :owner, business: create(:business))
      expect { approve_stock_count(count, outsider) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(count.reload).to be_completed
    end

    it "posts and reverses only in the count's warehouse" do
      receive!(shampoo, 4, into: other_warehouse)
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ shampoo, 10 ] ], complete: true)
      approve_stock_count(count, approver)
      reopen_stock_count(count, approver)
      expect(shampoo.stock_in(other_warehouse)).to eq(4)
      expect(InventoryMovement.where(source_type: "StockAdjustment").distinct.pluck(:warehouse_id)).to eq([ warehouse.id ])
    end
  end
end
