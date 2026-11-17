require "rails_helper"

# PR 5a — PATCH /inventory/stock_transfers/:id/void needs access to BOTH the
# source and the destination warehouse. A refused void changes nothing: no
# void stamp, no reversal movement.
RSpec.describe "Inventory::StockTransfers#void — warehouse access", type: :request do
  let(:business)     { create(:business) }
  let(:other)        { create(:business) }
  let!(:source)      { business.warehouses.create!(name: "Source") }
  let!(:destination) { business.warehouses.create!(name: "Destination") }
  let!(:elsewhere)   { business.warehouses.create!(name: "Elsewhere") }
  let(:product)      { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 5) }

  let!(:transfer) do
    InventoryMovement.create!(business: business, product: product, warehouse: source, direction: :in,
                              reason: :opening_balance, quantity: 10, unit_cost: 5, occurred_on: Date.new(2026, 1, 1))
    business.stock_transfers.build(source_warehouse: source, destination_warehouse: destination,
                                   transferred_on: Date.new(2026, 1, 2)).tap do |t|
      t.items.build(product: product, quantity: 4)
      expect(Inventory::StockTransferPoster.new(t).call).to be_ok
    end
  end

  def mover(*warehouses, business: self.business)
    user_with_stock_permissions(business, :view_inventory, :manage_stock_transfers).tap do |user|
      warehouses.each { |warehouse| WarehouseAssignment.create!(user: user, warehouse: warehouse) }
    end
  end

  def void_as(user)
    sign_in user
    patch void_inventory_stock_transfer_path(transfer), params: { void_reason: "Wrong quantity" }
  end

  def reversals = InventoryMovement.where(source: transfer, reason: "reversal")

  it "voids for a user with access to both warehouses" do
    void_as(mover(source, destination))

    expect(response).to redirect_to(inventory_stock_transfer_path(transfer))
    expect(transfer.reload.voided_at).to be_present
    expect(reversals.count).to eq(2)
  end

  def expect_refused_and_unchanged
    expect(response).to have_http_status(:redirect)
    expect(response).not_to redirect_to(inventory_stock_transfer_path(transfer))
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
    expect(transfer.reload.voided_at).to be_nil
    expect(reversals).to be_empty
  end

  it "refuses a user with access to the source only and changes nothing" do
    void_as(mover(source))
    expect_refused_and_unchanged
  end

  it "refuses a user with access to the destination only and changes nothing" do
    void_as(mover(destination))
    expect_refused_and_unchanged
  end

  it "refuses a user with access to neither warehouse (the transfer is not even visible)" do
    void_as(mover(elsewhere))

    expect(response).to have_http_status(:not_found)
    expect(transfer.reload.voided_at).to be_nil
    expect(reversals).to be_empty
  end

  it "refuses a user of another business" do
    void_as(user_with_stock_permissions(other, :view_inventory, :manage_stock_transfers))

    expect(response).to have_http_status(:not_found)
    expect(transfer.reload.voided_at).to be_nil
    expect(reversals).to be_empty
  end

  it "hides the void action from a one-sided user on the transfer page" do
    sign_in mover(source)
    get inventory_stock_transfer_path(transfer)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(void_inventory_stock_transfer_path(transfer))
  end
end
