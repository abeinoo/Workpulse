require "rails_helper"

# Warehouse Architecture PR 5 (D4) through the warehouse screens: only a
# business owner or an access_all_warehouses holder may create a warehouse.
RSpec.describe "Inventory::Warehouses — creation authorization", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:manager)  { user_with_stock_permissions(business, :view_inventory, :manage_inventory) }
  let(:company)  { user_with_stock_permissions(business, :view_inventory, :manage_inventory, :access_all_warehouses) }

  def create_warehouse(as:, name: "New Warehouse")
    sign_in as
    post inventory_warehouses_path, params: { warehouse: { name: name, status: "active" } }
  end

  it "lets the owner create a warehouse" do
    expect { create_warehouse(as: owner) }.to change(Warehouse, :count).by(1)
    expect(response).to redirect_to(inventory_warehouse_path(Warehouse.order(:id).last))
  end

  it "lets an access_all_warehouses holder create a warehouse" do
    expect { create_warehouse(as: company) }.to change(Warehouse, :count).by(1)
  end

  it "refuses manage_inventory alone — no warehouse is created" do
    expect { create_warehouse(as: manager) }.not_to change(Warehouse, :count)
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  it "refuses the new-warehouse page to manage_inventory alone" do
    sign_in manager
    get new_inventory_warehouse_path

    expect(response).to redirect_to(root_path)
  end

  it "shows the Add button only to those who may create" do
    sign_in manager
    get inventory_warehouses_path
    expect(response.body).not_to include(%(href="#{new_inventory_warehouse_path}"))

    sign_in owner
    get inventory_warehouses_path
    expect(response.body).to include(%(href="#{new_inventory_warehouse_path}"))
  end

  it "still lets manage_inventory edit a warehouse it can reach (update unchanged)" do
    warehouse = business.warehouses.create!(name: "Main")
    sign_in manager
    patch inventory_warehouse_path(warehouse), params: { warehouse: { name: "Renamed" } }

    expect(response).to redirect_to(inventory_warehouse_path(warehouse))
    expect(warehouse.reload.name).to eq("Renamed")
  end
end
