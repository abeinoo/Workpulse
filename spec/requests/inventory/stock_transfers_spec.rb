require "rails_helper"

# The Stock Transfer screens drive the approval workflow: creating saves a
# DRAFT (nothing reserved, nothing moved); submit reserves; approve posts;
# reject / cancel release. Every entry point authorizes itself.
RSpec.describe "Inventory::StockTransfers", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  def role_user(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s))
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:transfer_only) { role_user(:view_inventory, :manage_stock_transfers) }
  let(:viewer)        { role_user(:view_inventory) }
  let(:requester)     { role_user(:view_stock_transfers, :create_stock_transfers) }
  let(:approver) do
    role_user(:view_stock_transfers, :approve_stock_transfers, :edit_pending_stock_transfers,
              :reject_stock_transfers, :cancel_stock_transfers)
  end

  let!(:source) { business.warehouses.create!(name: "Main") }
  let!(:dest)   { business.warehouses.create!(name: "Branch") }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  before do
    r = business.goods_receipts.build(warehouse: source, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def transfer_params(qty)
    { stock_transfer: {
      source_warehouse_id: source.id, destination_warehouse_id: dest.id,
      items_attributes: { "0" => { product_id: product.id, quantity: qty } }
    } }
  end

  def reserved
    Inventory::StockAvailability.reserved_by(warehouse_ids: source.id, product_ids: product.id)[[ source.id, product.id ]].to_d
  end

  def create_as(user, qty)
    sign_in user
    post inventory_stock_transfers_path, params: transfer_params(qty)
    business.stock_transfers.order(:id).last
  end

  describe "GET pages" do
    before { sign_in owner }

    it "renders index (with status filter), new, show and edit" do
      get inventory_stock_transfers_path
      expect(response).to have_http_status(:ok)
      get inventory_stock_transfers_path(status: "pending_approval")
      expect(response).to have_http_status(:ok)
      get new_inventory_stock_transfer_path
      expect(response).to have_http_status(:ok)

      transfer = create_as(owner, 2)
      get inventory_stock_transfer_path(transfer)
      expect(response).to have_http_status(:ok)
      get edit_inventory_stock_transfer_path(transfer)
      expect(response).to have_http_status(:ok)
    end

    it "lets a transfer-only role (no inventory view) into the transfer screens" do
      sign_in requester
      get inventory_stock_transfers_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST create" do
    it "saves a draft — no reservation and no movement" do
      transfer = create_as(transfer_only, 4)
      expect(response).to redirect_to(inventory_stock_transfer_path(transfer))
      expect(transfer).to be_draft
      expect(product.stock_in(source)).to eq(10)
      expect(product.stock_in(dest)).to eq(0)
      expect(reserved).to eq(0)
    end

    it "re-renders an invalid request (422, nothing saved)" do
      sign_in owner
      post inventory_stock_transfers_path,
           params: transfer_params(1).deep_merge(stock_transfer: { destination_warehouse_id: source.id })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(business.stock_transfers.count).to eq(0)
    end
  end

  describe "the workflow over HTTP" do
    it "submit reserves; approve decides (still reserved, nothing moved)" do
      transfer = create_as(requester, 4)
      patch submit_inventory_stock_transfer_path(transfer)
      expect(transfer.reload).to be_pending_approval
      expect(reserved).to eq(4)

      sign_in approver
      patch approve_inventory_stock_transfer_path(transfer)
      expect(response).to redirect_to(inventory_stock_transfer_path(transfer))
      expect(transfer.reload).to be_awaiting_dispatch
      expect(product.stock_in(dest)).to eq(0)
      expect(reserved).to eq(4) # consumed only at dispatch
    end

    it "refuses an over-transfer at submission (nothing reserved or moved)" do
      transfer = create_as(requester, 99)
      patch submit_inventory_stock_transfer_path(transfer)
      expect(flash[:alert]).to include("Not enough stock")
      expect(transfer.reload).to be_draft
      expect(reserved).to eq(0)
    end

    it "reject needs a reason and releases the reservation" do
      transfer = create_as(requester, 3)
      patch submit_inventory_stock_transfer_path(transfer)
      sign_in approver
      patch reject_inventory_stock_transfer_path(transfer), params: { rejection_reason: "" }
      expect(transfer.reload).to be_pending_approval
      patch reject_inventory_stock_transfer_path(transfer), params: { rejection_reason: "not this week" }
      expect(transfer.reload).to be_rejected
      expect(reserved).to eq(0)
    end

    it "cancel needs a reason" do
      transfer = create_as(requester, 3)
      sign_in approver
      patch cancel_inventory_stock_transfer_path(transfer), params: { cancellation_reason: "dup" }
      expect(transfer.reload).to be_cancelled
    end

    it "an approver edits a pending transfer in place" do
      transfer = create_as(requester, 3)
      patch submit_inventory_stock_transfer_path(transfer)
      sign_in approver
      patch inventory_stock_transfer_path(transfer), params: {
        lock_token: transfer.reload.lock_token,
        stock_transfer: { items_attributes: { "0" => { id: transfer.items.first.id, product_id: product.id, quantity: 6 } } }
      }
      expect(response).to redirect_to(inventory_stock_transfer_path(transfer))
      expect(transfer.reload).to be_pending_approval
      expect(reserved).to eq(6)
    end

    it "returns live availability, excluding the transfer's own reservation" do
      transfer = create_as(requester, 4)
      patch submit_inventory_stock_transfer_path(transfer)
      get availability_inventory_stock_transfers_path(source_warehouse_id: source.id, destination_warehouse_id: dest.id,
                                                       product_ids: [ product.id ])
      row = response.parsed_body["products"].sole
      expect(row).to include("source_on_hand" => "10.0", "source_reserved" => "4.0", "source_available" => "6.0",
                             "destination_on_hand" => "0.0")
      get availability_inventory_stock_transfers_path(source_warehouse_id: source.id, destination_warehouse_id: dest.id,
                                                       product_ids: [ product.id ], stock_transfer_id: transfer.id)
      expect(response.parsed_body["products"].sole["source_reserved"]).to eq("0.0")
    end
  end

  describe "access control" do
    it "denies a view-only user from creating a transfer" do
      sign_in viewer
      post inventory_stock_transfers_path, params: transfer_params(1)
      expect(response).to redirect_to(root_path)
      expect(business.stock_transfers.count).to eq(0)
    end

    it "denies approval to a legacy manage_stock_transfers holder" do
      transfer = create_as(transfer_only, 2)
      patch submit_inventory_stock_transfer_path(transfer)
      expect(transfer.reload).to be_pending_approval
      patch approve_inventory_stock_transfer_path(transfer)
      expect(response).to redirect_to(root_path)
      expect(transfer.reload).to be_pending_approval
      expect(product.stock_in(dest)).to eq(0)
    end

    it "denies availability for a warehouse outside the user's reach" do
      scoped = requester.tap { |u| WarehouseAssignment.create!(user: u, warehouse: source) }
      sign_in scoped
      get availability_inventory_stock_transfers_path(source_warehouse_id: source.id, destination_warehouse_id: dest.id,
                                                       product_ids: [ product.id ])
      expect(response).to redirect_to(root_path)
    end
  end
end
