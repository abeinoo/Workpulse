require "rails_helper"

# BUG-063 through the product page's Delete action (ProductsController#destroy).
RSpec.describe "Inventory product deletion", type: :request do
  let(:business) { create(:business) }
  let!(:central) { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:nasr_wh) { business.warehouses.create!(name: "Nasr City WH", kind: "central") }
  let(:manager_a) do
    user_with_stock_permissions(business, :view_inventory, :manage_products).tap do |u|
      WarehouseAssignment.create!(user: u, warehouse: central)
    end
  end

  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5).tap do |p|
      p.product_barcodes.delete_all
      p.update!(active: false, archived_at: Time.current)
    end
  end

  it "a user scoped to one warehouse can no longer wipe every warehouse's settings by deleting the product" do
    product.product_warehouse_settings.create!(warehouse: central, low_stock_level: 3, reorder_quantity: 10)
    product.product_warehouse_settings.create!(warehouse: nasr_wh, low_stock_level: 5, reorder_quantity: 15)
    sign_in manager_a

    expect { delete inventory_product_path(product) }.not_to change(ProductWarehouseSetting, :count)
    expect(response).to redirect_to(inventory_product_path(product))
    expect(flash[:alert]).to eq(I18n.t("inventory.products.delete_referenced"))
    expect(Product.exists?(product.id)).to be(true)
  end

  it "deletes an archived product with no trace and shows the success message" do
    sign_in manager_a
    expect { delete inventory_product_path(product) }.to change(Product, :count).by(-1)
    expect(response).to redirect_to(inventory_products_path)
    expect(flash[:notice]).to eq(I18n.t("inventory.products.destroyed"))
    expect(AuditLog.where(action: "destroy", auditable_type: "Product").count).to eq(1)
  end

  it "refuses an active product even through a crafted request" do
    product.update!(active: true, archived_at: nil)
    sign_in manager_a
    expect { delete inventory_product_path(product) }.not_to change(Product, :count)
    expect(flash[:alert]).to eq(I18n.t("inventory.products.delete_requires_archive"))
  end
end
