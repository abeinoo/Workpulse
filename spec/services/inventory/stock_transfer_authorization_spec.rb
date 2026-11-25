require "rails_helper"

# Stock Transfer permissions — one per operation, independent of each other
# and of the legacy broad permissions (Inventory::StockTransferAuthorization),
# enforced by the policy AND by every workflow service; warehouse reach to
# BOTH ends is always required on top.
RSpec.describe "Stock transfer authorization" do
  let(:business) { create(:business) }
  let!(:source)    { business.warehouses.create!(name: "Main") }
  let!(:dest)      { business.warehouses.create!(name: "Branch") }
  let!(:elsewhere) { business.warehouses.create!(name: "Elsewhere") }
  let!(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }

  def operations
    { view: "view_stock_transfers", create: "create_stock_transfers", approve: "approve_stock_transfers",
      edit_pending: "edit_pending_stock_transfers", reject: "reject_stock_transfers", cancel: "cancel_stock_transfers",
      dispatch: "dispatch_stock_transfers", receive: "receive_stock_transfers", resolve: "resolve_stock_transfer_discrepancies" }
  end

  before do
    InventoryMovement.create!(business: business, product: product, warehouse: source, direction: :in, reason: :opening_balance,
                              quantity: 100, unit_cost: 10, occurred_on: Date.new(2026, 1, 1))
  end

  def user(*permissions, warehouses: [])
    user_with_stock_permissions(business, *permissions).tap do |u|
      warehouses.each { |w| WarehouseAssignment.create!(user: u, warehouse: w) }
    end
  end

  def transfer_in(status, from: source, to: dest)
    t = business.stock_transfers.build(source_warehouse: from, destination_warehouse: to)
    t.items.build(product: product, quantity: 5)
    save_stock_transfer_in_status!(t, status)
  end

  describe Inventory::StockTransferAuthorization do
    it "grants each operation only through its own permission (plus its view dependency)" do
      operations.each do |operation, permission|
        holder = user(*[ "view_stock_transfers", permission ].uniq)
        operations.each_key do |other|
          expect(described_class.permits?(holder, other)).to be([ :view, operation ].include?(other)),
                                                          "#{permission} -> #{other}"
        end
      end
    end

    it "keeps the legacy broad permissions' view/create — and never approval, editing, rejection or cancellation" do
      %w[manage_stock_transfers manage_inventory].each do |legacy|
        holder = user(:view_inventory, legacy)
        expect(described_class.permits?(holder, :view)).to be(true)
        expect(described_class.permits?(holder, :create)).to be(true)
        %i[approve edit_pending reject cancel dispatch receive resolve].each do |operation|
          expect(described_class.permits?(holder, operation)).to be(false), "#{legacy} -> #{operation}"
        end
      end
      expect(described_class.permits?(user(:view_inventory), :view)).to be(true)
      expect(described_class.permits?(user(:view_inventory), :create)).to be(false)
    end

    it "gives the owner every operation" do
      owner = create(:user, :owner, business: business)
      expect(operations.keys.all? { |op| described_class.permits?(owner, op) }).to be(true)
    end
  end

  describe "permission registry" do
    it "registers the nine permissions in their own group, each depending only on the transfer view" do
      expect(PermissionRole::PERMISSION_GROUPS[:stock_transfers]).to match_array(operations.values)
      (operations.values - %w[view_stock_transfers]).each do |permission|
        expect(PermissionRole::PERMISSION_DEPENDENCIES[permission]).to eq(%w[view_stock_transfers])
      end
      expect(PermissionRole::PERMISSION_DEPENDENCIES["approve_stock_transfers"]).not_to include("manage_stock_transfers")
    end

    it "lets approval be granted on its own (with only its view dependency)" do
      role = business.permission_roles.build(name: "Approver only", permissions: %w[view_stock_transfers approve_stock_transfers])
      expect(role).to be_valid
    end
  end

  describe "transit-workflow gates (policy)" do
    def transfer_with_status(status)
      t = business.stock_transfers.build(source_warehouse: source, destination_warehouse: dest, posting_mode: "via_transit",
                                         transfer_number: "TRF-#{SecureRandom.hex(3)}", transferred_on: Date.current,
                                         status: status, dispatched_at: Time.current, dispatched_on: Date.current,
                                         dispatched_by: create(:user, business: business))
      t.items.build(product: product, quantity: 1)
      t.save!(validate: false)
      t
    end

    it "dispatch needs the source, receive the destination, resolve both — each with its own permission" do
      awaiting    = transfer_with_status("awaiting_dispatch")
      on_the_road = transfer_with_status("in_transit")
      short       = transfer_with_status("discrepancy")
      dispatcher  = user(:view_stock_transfers, :dispatch_stock_transfers, warehouses: [ source ])
      receiver    = user(:view_stock_transfers, :receive_stock_transfers, warehouses: [ dest ])
      resolver_one_side = user(:view_stock_transfers, :resolve_stock_transfer_discrepancies, warehouses: [ dest ])
      resolver    = user(:view_stock_transfers, :resolve_stock_transfer_discrepancies, warehouses: [ source, dest ])

      expect(StockTransferPolicy.new(dispatcher, awaiting).dispatch?).to be(true)
      expect(StockTransferPolicy.new(receiver, awaiting).dispatch?).to be(false)
      expect(StockTransferPolicy.new(user(:view_stock_transfers, :dispatch_stock_transfers, warehouses: [ dest ]), awaiting).dispatch?).to be(false)
      expect(StockTransferPolicy.new(dispatcher, on_the_road).dispatch?).to be(false)

      expect(StockTransferPolicy.new(receiver, on_the_road).receive?).to be(true)
      expect(StockTransferPolicy.new(user(:view_stock_transfers, :receive_stock_transfers, warehouses: [ source ]), on_the_road).receive?).to be(false)
      expect(StockTransferPolicy.new(receiver, short).receive?).to be(false)

      expect(StockTransferPolicy.new(resolver, short).resolve?).to be(true)
      expect(StockTransferPolicy.new(resolver_one_side, short).resolve?).to be(false)
      expect(StockTransferPolicy.new(resolver, on_the_road).resolve?).to be(false)

      legacy = user(:view_inventory, :manage_inventory, :manage_stock_transfers)
      expect([ StockTransferPolicy.new(legacy, awaiting).dispatch?, StockTransferPolicy.new(legacy, on_the_road).receive?,
               StockTransferPolicy.new(legacy, short).resolve?, StockTransferPolicy.new(legacy, StockTransfer).receiving? ]).to all(be(false))
      expect(StockTransferPolicy.new(create(:user, :owner, business: business), short).resolve?).to be(true)
    end
  end

  describe StockTransferPolicy do
    def policy(user, record) = described_class.new(user, record)

    it "gates each action on its own permission and the transfer's status" do
      draft   = transfer_in(:draft)
      pending = transfer_in(:pending_approval)
      creator = user(:view_stock_transfers, :create_stock_transfers)
      expect(policy(creator, draft).update?).to be(true)
      expect(policy(creator, draft).submit?).to be(true)
      expect(policy(creator, pending).update?).to be(false)
      expect(policy(creator, pending).approve?).to be(false)

      expect(policy(user(:view_stock_transfers, :approve_stock_transfers), pending).approve?).to be(true)
      expect(policy(user(:view_stock_transfers, :approve_stock_transfers), draft).approve?).to be(false)
      expect(policy(user(:view_stock_transfers, :edit_pending_stock_transfers), pending).edit_pending?).to be(true)
      expect(policy(user(:view_stock_transfers, :reject_stock_transfers), pending).reject?).to be(true)
      expect(policy(user(:view_stock_transfers, :cancel_stock_transfers), draft).cancel?).to be(true)
      expect(policy(user(:view_stock_transfers, :cancel_stock_transfers), pending).cancel?).to be(true)
      expect(policy(user(:view_stock_transfers, :cancel_stock_transfers), transfer_in(:approved)).cancel?).to be(false)
    end

    it "requires access to both warehouses for every action" do
      pending = transfer_in(:pending_approval)
      partial = user(*operations.values, warehouses: [ source ])
      %i[approve? edit_pending? reject? cancel?].each do |action|
        expect(policy(partial, pending).public_send(action)).to be(false), action.to_s
      end
      full = user(*operations.values, warehouses: [ source, dest ])
      expect(policy(full, pending).approve?).to be(true)
    end

    it "never lets drafts be deleted" do
      expect(policy(create(:user, :owner, business: business), transfer_in(:draft)).destroy?).to be(false)
    end
  end

  describe "services enforce the permissions themselves" do
    let(:denied) { I18n.t("inventory.stock_transfers.errors.not_permitted") }

    it "refuses approval, editing, rejection and cancellation to legacy broad-permission holders" do
      pending = transfer_in(:pending_approval)
      legacy  = user(:view_inventory, :manage_inventory, :manage_stock_transfers)
      results = [
        Inventory::StockTransferApproval.new(stock_transfer_id: pending.id, actor: legacy).call,
        Inventory::StockTransferEditor.new(stock_transfer_id: pending.id, actor: legacy, attributes: { notes: "x" }).call,
        Inventory::StockTransferRejection.new(stock_transfer_id: pending.id, actor: legacy, reason: "x").call,
        Inventory::StockTransferCancellation.new(stock_transfer_id: pending.id, actor: legacy, reason: "x").call
      ]
      expect(results.map(&:error).uniq).to eq([ denied ])
      expect(pending.reload).to be_pending_approval
      expect(InventoryMovement.where(source_type: "StockTransfer")).to be_empty
    end

    it "lets a legacy holder still create and submit (view/create kept)" do
      legacy = user(:view_inventory, :manage_stock_transfers)
      result = Inventory::StockTransferDraftService.new(actor: legacy, attributes: {
        source_warehouse_id: source.id, destination_warehouse_id: dest.id,
        items_attributes: { "0" => { product_id: product.id, quantity: 2 } }
      }).call
      expect(result).to be_ok
      expect(Inventory::StockTransferSubmission.new(stock_transfer_id: result.transfer.id, actor: legacy).call).to be_ok
    end

    it "refuses submission without create_stock_transfers" do
      draft = transfer_in(:draft)
      approver = user(:view_stock_transfers, :approve_stock_transfers)
      expect(Inventory::StockTransferSubmission.new(stock_transfer_id: draft.id, actor: approver).call.error).to eq(denied)
    end

    it "refuses a draft into a warehouse the requester cannot reach" do
      scoped = user(:view_stock_transfers, :create_stock_transfers, warehouses: [ source ])
      result = Inventory::StockTransferDraftService.new(actor: scoped, attributes: {
        source_warehouse_id: source.id, destination_warehouse_id: dest.id,
        items_attributes: { "0" => { product_id: product.id, quantity: 2 } }
      }).call
      expect(result.error).to eq(I18n.t("inventory.errors.warehouse_not_accessible"))
      expect(StockTransfer.count).to eq(0)
    end

    it "approval permission does not grant warehouse access" do
      pending = transfer_in(:pending_approval)
      scoped  = user(:view_stock_transfers, :approve_stock_transfers, warehouses: [ dest ])
      expect(Inventory::StockTransferApproval.new(stock_transfer_id: pending.id, actor: scoped).call.error)
        .to eq(I18n.t("inventory.errors.warehouse_not_accessible"))
    end

    it "never reaches another business's transfer" do
      pending = transfer_in(:pending_approval)
      foreign = user_with_stock_permissions(create(:business), *operations.values)
      expect { Inventory::StockTransferApproval.new(stock_transfer_id: pending.id, actor: foreign).call }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe Inventory::PendingStockTransferApprovals do
    it "counts only pending transfers the user may approve in warehouses they reach at both ends" do
      transfer_in(:pending_approval)                         # Main -> Branch
      transfer_in(:pending_approval, from: elsewhere, to: dest)  # Elsewhere -> Branch
      transfer_in(:draft)
      transfer_in(:approved)

      expect(described_class.for(user(:view_stock_transfers, :approve_stock_transfers)).count).to eq(2)
      expect(described_class.for(user(:view_stock_transfers, :approve_stock_transfers, warehouses: [ source, dest ])).count).to eq(1)
      expect(described_class.for(user(:view_stock_transfers, :approve_stock_transfers, warehouses: [ dest ])).count).to eq(0)
      expect(described_class.for(user(:view_inventory, :manage_inventory, :manage_stock_transfers)).count).to eq(0)
      expect(described_class.for(user_with_stock_permissions(create(:business), :view_stock_transfers, :approve_stock_transfers)).count).to eq(0)
    end
  end
end
