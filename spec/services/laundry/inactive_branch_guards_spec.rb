require "rails_helper"

# BUG-029 — an inactive branch takes no new laundry operation, through the
# services (and the models under them), not only the branch pickers:
# * D1 towel transfers: no new transfer touching an inactive branch; a transfer
#   created before the deactivation may be dispatched from an inactive source
#   to an active destination, never to an inactive one; receiving or cancelling
#   one already in transit stays allowed;
# * D2 towel adjustments: no correction, loss or damage record there;
# * D4 laundry batches: no new batch there; existing ones keep their lifecycle.
RSpec.describe "Laundry operations at an inactive branch (BUG-029)", type: :model do
  let(:business)   { create(:business) }
  let(:actor)      { create(:user, business: business) }
  let(:sales)      { create(:branch, business: business, branch_type: "sales", name: "Sales") }
  let(:laundry)    { create(:branch, business: business, branch_type: "laundry", name: "Laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

  def fund(branch, status, quantity)
    result = Laundry::TowelAdjuster.new(actor: actor).call(towel_type: towel_type, branch: branch, status: status,
                                                           adjustment_quantity: quantity, reason: "setup")
    raise result.error unless result.ok?
  end

  def create_transfer(source:, destination:, quantity: 10)
    Laundry::TowelTransferCreator.create(actor: actor, params: {
      source_branch_id: source.id, destination_branch_id: destination.id,
      towel_status: TowelTransfer.infer_towel_status(source, destination),
      items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: quantity } ]
    })
  end

  def deactivate(branch) = branch.update_column(:active, false)
  def inactive_message   = I18n.t("activerecord.errors.messages.branch_inactive")

  describe "creating a towel transfer" do
    it "is refused when the source is inactive, writing nothing" do
      deactivate(sales)

      expect { @result = create_transfer(source: sales, destination: laundry) }
        .not_to change { [ TowelTransfer.count, AuditLog.where(auditable_type: "TowelTransfer").count ] }
      expect(@result).not_to be_ok
      expect(@result.transfer.errors.where(:source_branch, :branch_inactive)).to be_present
      expect(@result.error).to include(inactive_message)
    end

    it "is refused when the destination is inactive" do
      deactivate(laundry)

      result = create_transfer(source: sales, destination: laundry)

      expect(result).not_to be_ok
      expect(result.transfer.errors.where(:destination_branch, :branch_inactive)).to be_present
      expect(TowelTransfer.count).to eq(0)
    end

    it "still works between two active branches" do
      expect(create_transfer(source: sales, destination: laundry)).to be_ok
    end

    it "refuses moving an existing draft to an inactive branch" do
      other = create(:branch, business: business, branch_type: "laundry", name: "Old laundry")
      transfer = create_transfer(source: sales, destination: laundry).transfer
      deactivate(other)

      expect(transfer.update(destination_branch: other)).to be(false)
      expect(transfer.errors.where(:destination_branch, :branch_inactive)).to be_present
    end
  end

  describe "dispatching a transfer created before the deactivation" do
    it "is allowed from an inactive source to an active destination" do
      fund(sales, "clean", 20)
      transfer = create_transfer(source: sales, destination: laundry).transfer
      deactivate(sales)

      result = Laundry::TowelTransferCreator.new(transfer).dispatch(actor: actor)

      expect(result).to be_ok
      expect(transfer.reload).to be_dispatched
      expect(Laundry::TowelBalances.new(towel_type).at_branch(sales, "clean")).to eq(10)
    end

    it "is refused to an inactive destination, posting no ledger entry" do
      fund(sales, "clean", 20)
      transfer = create_transfer(source: sales, destination: laundry).transfer
      deactivate(laundry)

      expect { @result = Laundry::TowelTransferCreator.new(transfer).dispatch(actor: actor) }
        .not_to change(TowelLedgerEntry, :count)
      expect(@result).not_to be_ok
      expect(@result.error).to include(inactive_message)
      expect(transfer.reload).to be_draft
      expect(AuditLog.where(auditable: transfer, action: "dispatch")).to be_empty
    end
  end

  describe "a transfer already in transit to a branch deactivated afterwards" do
    let!(:transfer) do
      fund(sales, "clean", 20)
      create_transfer(source: sales, destination: laundry).transfer
        .tap { |t| Laundry::TowelTransferCreator.new(t).dispatch(actor: actor) }
    end

    before { deactivate(laundry) }

    it "can still be received there" do
      result = Laundry::TowelTransferCreator.new(transfer.reload)
                                            .receive(actor: actor, confirmed_quantities: { transfer.items.first.id => 10 })

      expect(result).to be_ok
      expect(transfer.reload).to be_received
      expect(Laundry::TowelBalances.new(towel_type).at_branch(laundry, "dirty")).to eq(10)
    end

    it "can still be cancelled, reversing the dispatch" do
      result = Laundry::TowelTransferCreator.new(transfer.reload).cancel(actor: actor, reason: "branch closed")

      expect(result).to be_ok
      expect(transfer.reload).to be_cancelled
      expect(Laundry::TowelBalances.new(towel_type).at_branch(sales, "clean")).to eq(20)
    end
  end

  describe "towel adjustments" do
    before { fund(sales, "clean", 20) }

    it "refuses a correction at an inactive branch, writing nothing" do
      deactivate(sales)

      expect {
        @result = Laundry::TowelAdjuster.new(actor: actor).call(towel_type: towel_type, branch: sales, status: "clean",
                                                                adjustment_quantity: -5, reason: "closing count")
      }.not_to change { [ TowelAdjustment.count, TowelLedgerEntry.count ] }
      expect(@result).not_to be_ok
      expect(@result.error).to include(inactive_message)
    end

    %w[lost damaged].each do |kind|
      it "refuses a #{kind} record at an inactive branch" do
        deactivate(sales)

        expect {
          @result = Laundry::TowelAdjuster.new(actor: actor).record_loss(towel_type: towel_type, branch: sales,
                                                                         adjustment_type: kind, quantity: 2, reason: "x")
        }.not_to change { [ TowelAdjustment.count, TowelLedgerEntry.count ] }
        expect(@result).not_to be_ok
      end
    end

    it "keeps working at an active branch" do
      result = Laundry::TowelAdjuster.new(actor: actor).record_loss(towel_type: towel_type, branch: sales,
                                                                    adjustment_type: "lost", quantity: 2, reason: "x")
      expect(result).to be_ok
    end
  end

  describe "laundry batches" do
    it "refuses a new batch at an inactive laundry" do
      deactivate(laundry)

      expect {
        @result = Laundry::LaundryBatchService.create(actor: actor, laundry_branch_id: laundry.id, towel_type_id: towel_type.id)
      }.not_to change(LaundryBatch, :count)
      expect(@result).not_to be_ok
      expect(@result.batch.errors.where(:laundry_branch, :branch_inactive)).to be_present
    end

    it "lets a batch opened before the deactivation run to completion" do
      fund(laundry, "dirty", 10)
      batch = Laundry::LaundryBatchService.create(actor: actor, laundry_branch_id: laundry.id, towel_type_id: towel_type.id).batch
      deactivate(laundry)

      service = Laundry::LaundryBatchService.new(batch)
      expect(service.start(actor: actor, input_quantity: 10)).to be_ok
      expect(batch.reload).to be_in_progress
    end
  end

  it "keeps business isolation: a foreign active branch is still refused as invalid" do
    foreign = create(:branch, business: create(:business), branch_type: "laundry")

    result = create_transfer(source: sales, destination: foreign)

    expect(result).not_to be_ok
    expect(result.transfer.errors.where(:destination_branch, :invalid)).to be_present
  end
end
