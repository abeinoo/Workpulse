require "rails_helper"

# Phase 1 unit 6: the product form's nested product_warehouse_settings_attributes
# must never delete, re-point or edit an Inactive availability row — removing
# it would turn the pair back into Not Configured and lift the incoming-stock
# block. Only Inventory::ProductAvailabilityManager changes an Inactive row.
RSpec.describe "Product form — Inactive availability rows", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:wh_a)    { business.warehouses.create!(name: "Warehouse A") }
  let!(:wh_b)    { business.warehouses.create!(name: "Warehouse B") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }

  let!(:inactive) do
    manager = Inventory::ProductAvailabilityManager.new(actor: owner)
    manager.add_many(warehouse_id: wh_a.id, items: [ { product_id: product.id, low_stock_level: 3, reorder_quantity: 10 } ])
    row = ProductWarehouseSetting.find_by!(product: product, warehouse: wh_a)
    manager.deactivate(setting_id: row.id, reason: "not sold here")
    row.reload
  end

  def update_settings(attrs)
    patch inventory_product_path(product), params: {
      product: { name: product.name, sku: product.sku, product_warehouse_settings_attributes: attrs }
    }
  end

  def snapshot = ProductWarehouseSetting.order(:id).pluck(:id, :warehouse_id, :status, :low_stock_level, :reorder_quantity)

  before { sign_in owner }

  {
    "deleting it"         => ->(row, _other) { { id: row.id, _destroy: "1" } },
    "re-pointing it"      => ->(row, other)  { { id: row.id, warehouse_id: other.id } },
    "changing its values" => ->(row, _other) { { id: row.id, warehouse_id: row.warehouse_id, low_stock_level: 99, reorder_quantity: 99 } }
  }.each do |label, payload|
    it "refuses #{label}, even for the owner, and changes nothing" do
      before = snapshot

      update_settings("0" => payload.call(inactive, wh_b))

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      expect(snapshot).to eq(before)
    end
  end

  it "does not render the Inactive row in the edit form, so ordinary product saves never submit it" do
    get edit_inventory_product_path(product)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("product_warehouse_settings_attributes][0][id]")

    update_settings({})
    expect(inactive.reload).to be_status_inactive
  end

  describe "model backstop (any other path)" do
    it "refuses destroying an Inactive row" do
      expect(inactive.destroy).to be(false)
      expect(inactive.errors[:base]).to include(I18n.t("activerecord.errors.models.product_warehouse_setting.attributes.base.inactive_row_locked"))
      expect(ProductWarehouseSetting.exists?(inactive.id)).to be(true)
    end

    it "refuses changing an Inactive row's warehouse or settings" do
      expect(inactive.update(warehouse: wh_b)).to be(false)
      expect(inactive.reload.update(low_stock_level: 7)).to be(false)
      expect(inactive.reload.attributes.values_at("warehouse_id", "low_stock_level")).to eq([ wh_a.id, 3 ])
    end

    it "still lets the availability service reactivate it with its kept settings" do
      result = Inventory::ProductAvailabilityManager.new(actor: owner).reactivate(setting_id: inactive.id)
      expect(result).to be_ok
      expect(inactive.reload).to have_attributes(status: "active", low_stock_level: 3, reorder_quantity: 10)
    end
  end
end
