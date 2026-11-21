require "rails_helper"

# Phase 0 (warehouse product availability plan): the product form's nested
# product_warehouse_settings_attributes must never let a user create, change,
# re-point or delete a per-warehouse setting of a warehouse outside their
# inventory warehouse scope (User#inventory_warehouse_ids), nor reach another
# business's warehouse or setting row. Enforced server-side — the edit form
# also stops rendering out-of-scope rows, but nothing here relies on that.
#
# Phase 2 (product availability per warehouse): the product form no longer
# writes per-warehouse rows at all — Inventory::ProductAvailabilityManager is
# the only writer (audited). Every nested payload is now refused, in or out of
# scope; the refusals below stay as they were, and the formerly allowed
# in-scope writes are refused too.
RSpec.describe "Product warehouse settings — warehouse and business scope", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  let!(:wh_a) { business.warehouses.create!(name: "Warehouse A") }
  let!(:wh_b) { business.warehouses.create!(name: "Warehouse B") }
  # Out of scope for manager_a and holding no setting row, so an add or re-point
  # into it is refused by the scope guard alone (not by the unique index).
  let!(:wh_c) { business.warehouses.create!(name: "Warehouse C") }

  let(:other_business) { create(:business) }
  let!(:foreign_wh)    { other_business.warehouses.create!(name: "Foreign WH") }

  # Can edit products, assigned ONLY to Warehouse A.
  let(:manager_a) do
    role = business.permission_roles.create!(name: "Product Manager A", permissions: %w[view_inventory manage_products])
    user = create(:user, business: business)
    user.update_column(:permission_role_id, role.id)
    user.assigned_warehouses << wh_a
    user
  end

  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end
  let!(:setting_a) { product.product_warehouse_settings.create!(warehouse: wh_a, low_stock_level: 3, reorder_quantity: 10) }
  let!(:setting_b) { product.product_warehouse_settings.create!(warehouse: wh_b, low_stock_level: 5, reorder_quantity: 15) }

  def update_settings(attrs)
    patch inventory_product_path(product), params: {
      product: { name: product.name, sku: product.sku, product_warehouse_settings_attributes: attrs }
    }
  end

  def setting_snapshot
    ProductWarehouseSetting.order(:id).pluck(:id, :product_id, :warehouse_id, :low_stock_level, :reorder_quantity)
  end

  shared_examples "a refused settings write" do
    it "redirects as not authorized and changes no setting row" do
      before = setting_snapshot
      yield_request
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      expect(setting_snapshot).to eq(before)
    end
  end

  describe "a warehouse-scoped user (assigned to Warehouse A only)" do
    before { sign_in manager_a }

    context "adding a setting for a warehouse outside their scope" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) { update_settings("0" => { warehouse_id: wh_c.id, low_stock_level: 1, reorder_quantity: 1 }) }
      end
    end

    context "changing another warehouse's existing setting" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings("0" => { id: setting_b.id, warehouse_id: wh_b.id, low_stock_level: 99, reorder_quantity: 99 })
        end
      end
    end

    context "deleting another warehouse's existing setting" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings("0" => { id: setting_b.id, warehouse_id: wh_b.id, _destroy: "1" })
        end
      end
    end

    # Rails skips reject_if for a row marked _destroy (allow_destroy), so a
    # bare id + _destroy — no warehouse_id at all — still deletes the row.
    context "deleting another warehouse's setting by id alone" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) { update_settings("0" => { id: setting_b.id, _destroy: "1" }) }
      end
    end

    context "using the single-row (non-indexed) nested attributes form" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) { update_settings({ id: setting_b.id, _destroy: "1" }) }
      end
    end

    context "using the array nested attributes form" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings([ { warehouse_id: wh_c.id, low_stock_level: 1, reorder_quantity: 1 } ])
        end
      end
    end

    context "re-pointing their own setting at another warehouse" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings("0" => { id: setting_a.id, warehouse_id: wh_c.id, low_stock_level: 3, reorder_quantity: 10 })
        end
      end
    end

    context "taking over another warehouse's setting by naming their own warehouse" do
      # Warehouse A has no row of its own here, so the unique index can't be
      # what refuses moving B's row into A.
      before { setting_a.destroy! }

      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings("0" => { id: setting_b.id, warehouse_id: wh_a.id, low_stock_level: 1, reorder_quantity: 1 })
        end
      end
    end

    context "naming another business's warehouse" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings("0" => { warehouse_id: foreign_wh.id, low_stock_level: 1, reorder_quantity: 1 })
        end
      end
    end

    context "mixing an allowed row with a forbidden one" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings(
            "0" => { id: setting_a.id, warehouse_id: wh_a.id, low_stock_level: 7, reorder_quantity: 7 },
            "1" => { warehouse_id: wh_c.id, low_stock_level: 1, reorder_quantity: 1 }
          )
        end
      end
    end

    it "cannot create a product carrying a setting for a warehouse outside their scope" do
      expect {
        post inventory_products_path, params: {
          product: { name: "Mask", sku: "MK-1", initial_cost_price: 5,
                     product_warehouse_settings_attributes: { "0" => { warehouse_id: wh_b.id, low_stock_level: 2, reorder_quantity: 4 } } }
        }
      }.not_to change { [ Product.count, ProductWarehouseSetting.count ] }
      expect(response).to redirect_to(root_path)
    end

    # Phase 2: their own warehouse's row is changed through the availability
    # service (warehouse Products tab / product page), not the product form.
    context "changing the setting of their own warehouse through the product form" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings("0" => { id: setting_a.id, warehouse_id: wh_a.id, low_stock_level: 8, reorder_quantity: 12 })
        end
      end
    end

    context "deleting the setting of their own warehouse through the product form" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) { update_settings("0" => { id: setting_a.id, warehouse_id: wh_a.id, _destroy: "1" }) }
      end
    end

    it "can still save the product without touching any setting" do
      patch inventory_product_path(product), params: { product: { name: "Shampoo Pro", sku: product.sku } }
      expect(response).to redirect_to(inventory_product_path(product))
      expect(product.reload.name).to eq("Shampoo Pro")
      expect(setting_b.reload.low_stock_level).to eq(5)
    end

    it "is not shown any warehouse's setting row on the edit form (Phase 2: none is rendered)" do
      setting_b.update!(low_stock_level: 4321)
      get edit_inventory_product_path(product)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("product_warehouse_settings_attributes")
      expect(response.body).not_to include(%(value="#{setting_a.id}"))
      expect(response.body).not_to include(%(value="#{setting_b.id}"))
      expect(response.body).not_to include("4321")
    end
  end

  describe "a user without a warehouse restriction (owner)" do
    before { sign_in owner }

    # Phase 2: not even an owner writes availability through the product form.
    context "changing or deleting settings of the business's warehouses through the product form" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings(
            "0" => { id: setting_b.id, warehouse_id: wh_b.id, low_stock_level: 6, reorder_quantity: 16 },
            "1" => { id: setting_a.id, warehouse_id: wh_a.id, _destroy: "1" }
          )
        end
      end
    end

    context "naming another business's warehouse" do
      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings("0" => { warehouse_id: foreign_wh.id, low_stock_level: 1, reorder_quantity: 1 })
        end
      end
    end

    context "naming another business's setting row" do
      let!(:foreign_product) do
        other_business.products.create!(name: "Foreign", sku: "FX-1", initial_cost_price: 1, average_cost_price: 1)
      end
      let!(:foreign_setting) do
        foreign_product.product_warehouse_settings.create!(warehouse: foreign_wh, low_stock_level: 2, reorder_quantity: 2)
      end

      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings("0" => { id: foreign_setting.id, warehouse_id: wh_a.id, low_stock_level: 9, reorder_quantity: 9 })
        end
      end

      it_behaves_like "a refused settings write" do
        define_method(:yield_request) do
          update_settings("0" => { id: foreign_setting.id, warehouse_id: foreign_wh.id, _destroy: "1" })
        end
      end
    end

    it "cannot create a product carrying a setting for another business's warehouse" do
      expect {
        post inventory_products_path, params: {
          product: { name: "Mask", sku: "MK-1", initial_cost_price: 5,
                     product_warehouse_settings_attributes: { "0" => { warehouse_id: foreign_wh.id, low_stock_level: 2, reorder_quantity: 4 } } }
        }
      }.not_to change { [ Product.count, ProductWarehouseSetting.count ] }
      expect(response).to redirect_to(root_path)
    end
  end
end
