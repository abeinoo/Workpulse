require "rails_helper"

RSpec.describe Laundry::TowelTransferCreator, type: :model do
  let(:business) { create(:business) }
  let(:source_branch) { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:other_towel_type) { business.towel_types.create!(name: "Hand Towel") }
  let(:actor) { create(:user, business: business) }

  def balances(type = towel_type)
    Laundry::TowelBalances.new(type)
  end

  # Simulates an existing balance via the Towel Adjustments mechanism —
  # mirrors how a real business would fund a branch's starting stock.
  def fund(branch, status, quantity, type: towel_type)
    Laundry::TowelAdjuster.new(actor: actor).call(
      towel_type: type, branch: branch, status: status,
      adjustment_quantity: quantity, reason: "test setup"
    )
  end

  def build_transfer(source: source_branch, destination: laundry_branch, towel_status: "dirty", quantity: 100,
                     items: nil)
    items_attributes = items || [ { towel_type_id: towel_type.id, declared_quantity: quantity } ]
    described_class.create(actor: actor, params: {
      source_branch_id: source.id, destination_branch_id: destination.id,
      towel_status: towel_status, items_attributes: items_attributes
    }).transfer
  end

  # confirmed: either a single quantity (applied to the transfer's one item)
  # or a { towel_type => quantity } hash for a multi-item transfer.
  def do_receive(transfer, confirmed)
    quantities = if confirmed.is_a?(Hash)
                   confirmed.transform_keys { |type| transfer.items.find { |i| i.towel_type == type }.id }
    else
                   { transfer.items.first.id => confirmed }
    end
    described_class.new(transfer).receive(actor: actor, confirmed_quantities: quantities)
  end

  it "does not touch the ledger while draft" do
    result = described_class.create(actor: actor, params: {
      source_branch_id: source_branch.id, destination_branch_id: laundry_branch.id, towel_status: "dirty",
      items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: 100 } ]
    })

    expect(result.ok?).to be(true)
    expect(balances.at_branch(source_branch, "clean")).to eq(0)
  end

  it "creates successfully without any loss/damage fields — they no longer exist on the transfer" do
    result = build_transfer(quantity: 50)

    expect(result).to be_persisted
    expect(TowelTransfer.column_names).not_to include("loss_quantity", "loss_reason")
  end

  it "rejects a transfer whose branch combination can't be inferred, instead of falling back to a manual condition" do
    hq_branch = create(:branch, business: business, branch_type: "headquarters")

    result = described_class.create(actor: actor, params: {
      source_branch_id: hq_branch.id, destination_branch_id: source_branch.id, towel_status: nil,
      items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: 10 } ]
    })

    expect(result.ok?).to be(false)
    expect(result.transfer.errors[:towel_status]).to be_present
  end

  it "rejects a transfer with two line items for the same towel type" do
    result = described_class.create(actor: actor, params: {
      source_branch_id: source_branch.id, destination_branch_id: laundry_branch.id, towel_status: "dirty",
      items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: 10 },
                          { towel_type_id: towel_type.id, declared_quantity: 5 } ]
    })

    expect(result.ok?).to be(false)
  end

  it "rejects a transfer with zero line items" do
    result = described_class.create(actor: actor, params: {
      source_branch_id: source_branch.id, destination_branch_id: laundry_branch.id, towel_status: "dirty",
      items_attributes: []
    })

    expect(result.ok?).to be(false)
  end

  describe "a sales branch -> laundry (dirty) transfer" do
    it "dispatch debits the source's CLEAN balance (never a 'dirty held at branch' balance), receive credits the laundry's dirty balance" do
      fund(source_branch, "clean", 100)
      transfer = build_transfer(quantity: 50)

      dispatch = described_class.new(transfer).dispatch(actor: actor)
      expect(dispatch.ok?).to be(true)
      expect(balances.at_branch(source_branch, "clean")).to eq(50) # 100 - 50, matches "Branch A: Clean: -50"
      expect(balances.in_transit).to eq(50)

      receive = do_receive(transfer.reload, 50)
      expect(receive.ok?).to be(true)
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(50)
      expect(balances.in_transit).to eq(0)
    end

    it "rejects dispatch when the source doesn't have enough clean stock" do
      fund(source_branch, "clean", 30)
      transfer = build_transfer(quantity: 50)

      result = described_class.new(transfer).dispatch(actor: actor)

      expect(result.ok?).to be(false)
      expect(transfer.reload).to be_draft
      expect(balances.at_branch(source_branch, "clean")).to eq(30)
    end
  end

  describe "receive preserves the declared quantity and surfaces a discrepancy" do
    it "credits only the CONFIRMED quantity, never the declared one" do
      fund(source_branch, "clean", 100)
      transfer = build_transfer(quantity: 100)
      described_class.new(transfer).dispatch(actor: actor)

      result = do_receive(transfer.reload, 98)

      expect(result.ok?).to be(true)
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(98)
      expect(transfer.reload.items.first.declared_quantity).to eq(100) # never silently modified
      expect(transfer.discrepancy).to eq(2)
    end
  end

  describe "receive rejects an over-receipt (confirmed > declared)" do
    it "accepts confirmed equal to declared, with zero discrepancy" do
      fund(source_branch, "clean", 50)
      transfer = build_transfer(quantity: 50)
      described_class.new(transfer).dispatch(actor: actor)

      result = do_receive(transfer.reload, 50)

      expect(result.ok?).to be(true)
      expect(transfer.reload.discrepancy).to eq(0)
    end

    it "accepts confirmed less than declared, recorded as a positive shortage discrepancy" do
      fund(source_branch, "clean", 50)
      transfer = build_transfer(quantity: 50)
      described_class.new(transfer).dispatch(actor: actor)

      result = do_receive(transfer.reload, 48)

      expect(result.ok?).to be(true)
      expect(transfer.reload.discrepancy).to eq(2)
    end

    it "rejects confirmed greater than declared with the exact required message, and posts no ledger entry" do
      fund(source_branch, "clean", 50)
      transfer = build_transfer(quantity: 50)
      described_class.new(transfer).dispatch(actor: actor)
      ledger_count_before = TowelLedgerEntry.count

      result = do_receive(transfer.reload, 55)

      expect(result.ok?).to be(false)
      expect(result.error).to eq("The received quantity cannot exceed the dispatched quantity. Dispatched quantity: 50.")
      expect(transfer.reload).to be_dispatched # not received
      expect(transfer.items.first.confirmed_quantity).to be_nil
      expect(TowelLedgerEntry.count).to eq(ledger_count_before) # no entry posted, not even a rolled-back one persisted
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(0) # nothing credited
    end

    it "leaves the transfer receivable again after a rejected over-receipt attempt" do
      fund(source_branch, "clean", 50)
      transfer = build_transfer(quantity: 50)
      described_class.new(transfer).dispatch(actor: actor)
      do_receive(transfer.reload, 55)

      result = do_receive(transfer.reload, 50)

      expect(result.ok?).to be(true)
      expect(transfer.reload).to be_received
      expect(transfer.items.first.confirmed_quantity).to eq(50)
    end
  end

  describe "a laundry -> sales branch (clean) return" do
    def build_return(clean_quantity: 49)
      build_transfer(source: laundry_branch, destination: source_branch, towel_status: "clean",
                     quantity: clean_quantity)
    end

    it "converts dirty stock into clean 1:1, ships it, and the destination receives only what's confirmed" do
      fund(laundry_branch, "dirty", 50)
      transfer = build_return(clean_quantity: 50)

      dispatch = described_class.new(transfer).dispatch(actor: actor)
      expect(dispatch.ok?).to be(true)
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(0) # 50 consumed
      expect(balances.at_branch(laundry_branch, "clean")).to eq(0) # produced 50, immediately dispatched — nets to 0

      receive = do_receive(transfer.reload, 50)
      expect(receive.ok?).to be(true)
      expect(balances.at_branch(source_branch, "clean")).to eq(50)
    end

    it "rejects dispatch when the laundry doesn't have enough dirty stock to cover the declared quantity" do
      fund(laundry_branch, "dirty", 40) # less than 49
      transfer = build_return

      result = described_class.new(transfer).dispatch(actor: actor)

      expect(result.ok?).to be(false)
      expect(transfer.reload).to be_draft
    end

    it "does not create a TowelAdjustment or touch lost/damaged buckets — a receipt discrepancy is investigation-only" do
      fund(laundry_branch, "dirty", 50)
      transfer = build_return(clean_quantity: 50)
      described_class.new(transfer).dispatch(actor: actor)

      expect {
        do_receive(transfer.reload, 48)
      }.not_to change(TowelAdjustment, :count)

      expect(transfer.reload.discrepancy).to eq(2)
      expect(balances.at_branch(laundry_branch, "lost")).to eq(0)
      expect(balances.at_branch(laundry_branch, "damaged")).to eq(0)
    end
  end

  describe "multi-item transfers" do
    it "posts one ledger entry per line item on dispatch, and validates availability per towel type" do
      fund(source_branch, "clean", 100, type: towel_type)
      fund(source_branch, "clean", 50, type: other_towel_type)
      transfer = build_transfer(items: [
        { towel_type_id: towel_type.id, declared_quantity: 40 },
        { towel_type_id: other_towel_type.id, declared_quantity: 20 }
      ])

      result = described_class.new(transfer).dispatch(actor: actor)

      expect(result.ok?).to be(true)
      expect(TowelLedgerEntry.where(source: transfer, reason: "towel_transfer_dispatch").count).to eq(2)
      expect(balances(towel_type).at_branch(source_branch, "clean")).to eq(60)
      expect(balances(other_towel_type).at_branch(source_branch, "clean")).to eq(30)
    end

    it "aborts the whole dispatch (no partial dispatch) when any single line item lacks availability" do
      fund(source_branch, "clean", 100, type: towel_type)
      fund(source_branch, "clean", 5, type: other_towel_type) # not enough for the 20 requested below
      transfer = build_transfer(items: [
        { towel_type_id: towel_type.id, declared_quantity: 40 },
        { towel_type_id: other_towel_type.id, declared_quantity: 20 }
      ])

      result = described_class.new(transfer).dispatch(actor: actor)

      expect(result.ok?).to be(false)
      expect(transfer.reload).to be_draft
      expect(TowelLedgerEntry.where(source: transfer)).to be_empty
      # The towel type with sufficient stock was NOT debited either — all-or-nothing.
      expect(balances(towel_type).at_branch(source_branch, "clean")).to eq(100)
    end

    it "receives different confirmed quantities per line item in one receipt confirmation" do
      fund(source_branch, "clean", 100, type: towel_type)
      fund(source_branch, "clean", 50, type: other_towel_type)
      transfer = build_transfer(items: [
        { towel_type_id: towel_type.id, declared_quantity: 40 },
        { towel_type_id: other_towel_type.id, declared_quantity: 20 }
      ])
      described_class.new(transfer).dispatch(actor: actor)

      result = do_receive(transfer.reload, { towel_type => 38, other_towel_type => 20 })

      expect(result.ok?).to be(true)
      expect(balances(towel_type).at_branch(laundry_branch, "dirty")).to eq(38)
      expect(balances(other_towel_type).at_branch(laundry_branch, "dirty")).to eq(20)
      expect(transfer.reload.discrepancy).to eq(2)
    end
  end

  describe "cancel" do
    it "before dispatch has no ledger impact" do
      transfer = build_transfer

      described_class.new(transfer).cancel(actor: actor, reason: "wrong branch")

      expect(transfer.reload).to be_cancelled
      expect(balances.at_branch(source_branch, "clean")).to eq(0)
    end

    it "after a simple dispatch reverses the single posted entry" do
      fund(source_branch, "clean", 100)
      transfer = build_transfer(quantity: 100)
      described_class.new(transfer).dispatch(actor: actor)

      described_class.new(transfer.reload).cancel(actor: actor, reason: "pickup fell through")

      expect(transfer.reload).to be_cancelled
      expect(balances.at_branch(source_branch, "clean")).to eq(100)
    end

    it "after a wash-conversion dispatch reverses every entry it posted (dirty consumed, clean produced, dispatch)" do
      fund(laundry_branch, "dirty", 50)
      transfer = build_transfer(source: laundry_branch, destination: source_branch, towel_status: "clean",
                                quantity: 50)
      described_class.new(transfer).dispatch(actor: actor)

      described_class.new(transfer.reload).cancel(actor: actor, reason: "miscounted")

      expect(transfer.reload).to be_cancelled
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(50) # fully restored
      expect(balances.at_branch(laundry_branch, "clean")).to eq(0)
    end

    it "after a received transfer reverses the receipt entry too — a service-level correction path for bad historical data" do
      fund(source_branch, "clean", 50)
      transfer = build_transfer(quantity: 50)
      described_class.new(transfer).dispatch(actor: actor)
      do_receive(transfer.reload, 50)

      result = described_class.new(transfer.reload).cancel(actor: actor, reason: "correcting bad historical data")

      expect(result.ok?).to be(true)
      expect(transfer.reload).to be_cancelled
      expect(balances.at_branch(source_branch, "clean")).to eq(50)   # restored at the source
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(0)   # removed from the destination
    end
  end

  it "rejects a receive on an already-received transfer (race safety) and does not double-credit the balance" do
    fund(source_branch, "clean", 100)
    transfer = build_transfer(quantity: 100)
    described_class.new(transfer).dispatch(actor: actor)
    do_receive(transfer.reload, 100)

    second = do_receive(transfer.reload, 100)

    expect(second.ok?).to be(false)
    expect(balances.at_branch(laundry_branch, "dirty")).to eq(100)
  end

  it "rejects a second dispatch attempt (cannot dispatch twice) and does not double-debit the balance" do
    fund(source_branch, "clean", 100)
    transfer = build_transfer(quantity: 100)
    described_class.new(transfer).dispatch(actor: actor)

    second = described_class.new(transfer.reload).dispatch(actor: actor)

    expect(second.ok?).to be(false)
    expect(balances.at_branch(source_branch, "clean")).to eq(0)
  end
end
