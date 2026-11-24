require "rails_helper"

# The Product Family feature (parent / child products) was removed. Every
# product stands on its own: no parent selector, family section, tree, filter,
# "Archive family", children list, family stock or family-specific refusal.
# A parent link still stored in products.parent_product_id (existing data,
# until the column is dropped) is ignored everywhere, and no stock, movement
# or document is changed by the removal.
RSpec.describe "Product Family removed", type: :request do
  let(:business)  { create(:business) }
  let(:other)     { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let(:counter)   { user_with_stock_permissions(business, :view_inventory, :manage_stock_counts) }
  let(:approver)  { user_with_stock_permissions(business, :view_inventory, :post_stock_counts) }
  let!(:central)  { business.warehouses.create!(name: "Central WH", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City WH", kind: "branch", branch: create(:branch, business: business)) }
  let!(:former_parent) { business.products.create!(name: "Shampoo Family", sku: "FAM", initial_cost_price: 5, average_cost_price: 5) }
  let!(:former_child)  { business.products.create!(name: "Shampoo 1L", sku: "FAM-1L", initial_cost_price: 5, average_cost_price: 5) }

  def doc = Nokogiri::HTML(response.body)

  # The link as an existing database still holds it.
  def link_in_database!(child, parent)
    Product.connection.execute(Product.sanitize_sql_array([ "UPDATE products SET parent_product_id = ? WHERE id = ?", parent.id, child.id ]))
  end

  def receive!(product, warehouse, qty)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: qty, unit_cost: 5)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
  end

  def on_hand(product, warehouse) = Inventory::StockLevels.new(product).in_warehouse(warehouse).to_d

  before do
    link_in_database!(former_child, former_parent)
    sign_in owner
  end

  describe "products" do
    it "has no family associations, scopes, predicates or actions" do
      %i[parent_product child_products parent? child? archive_family! force_non_tracking! parent_product_id].each do |name|
        expect(former_parent).not_to respond_to(name)
      end
      %i[non_parent root_parents children standalone].each { |scope| expect(Product).not_to respond_to(scope) }
      expect(Product.column_names).not_to include("parent_product_id")
      expect(Product.transactable).to include(former_parent, former_child)
      expect(ProductPolicy.new(owner, former_parent)).not_to respond_to(:archive_family?)
    end

    it "creates and edits a product without any parent relationship; a crafted parent id is ignored" do
      foreign = other.products.create!(name: "Foreign", sku: "FX-1", initial_cost_price: 1, average_cost_price: 1)
      foreign_before = foreign.reload.attributes

      get new_inventory_product_path
      expect(response).to have_http_status(:ok)
      expect(doc.css("[name='product[parent_product_id]']")).to be_empty

      post inventory_products_path, params: { product: { name: "Conditioner", sku: "CN-1", initial_cost_price: 3, parent_product_id: former_parent.id } }
      created = business.products.find_by!(sku: "CN-1")
      expect(response).to redirect_to(inventory_product_path(created))
      expect(raw_parent_product_id(created)).to be_nil
      expect(created).to be_track_inventory

      patch inventory_product_path(created), params: { product: { name: "Conditioner Pro", sku: "CN-1", parent_product_id: foreign.id } }
      expect(response).to redirect_to(inventory_product_path(created))
      expect(created.reload.name).to eq("Conditioner Pro")
      expect(raw_parent_product_id(created)).to be_nil
      expect(foreign.reload.attributes).to eq(foreign_before)
    end

    it "Edit, Show and the list show no family section, selector, badge, filter or tree" do
      [ edit_inventory_product_path(former_parent), inventory_product_path(former_parent),
        inventory_product_path(former_child), inventory_products_path ].each do |path|
        get path
        expect(response).to have_http_status(:ok), path
        expect(response.body).not_to include("Product Family", "Parent Product", "Child Products", "Archive Family",
                                             "family total", "product-family", "family_type", "/children")
        expect(doc.css("[name='product[parent_product_id]'], [name='family_type']")).to be_empty
      end

      get inventory_products_path
      rows = doc.css("tbody tr [data-testid='product-sku'] bdi").map { |sku| sku.text.strip } # each row's SKU
      expect(rows).to include("FAM", "FAM-1L") # both listed as ordinary rows
    end

    it "keeps both former family members as ordinary products: tracked, archivable one by one" do
      expect(former_parent.reload).to be_track_inventory
      patch archive_inventory_product_path(former_parent)
      expect(response).to redirect_to(inventory_product_path(former_parent))
      expect(former_parent.reload).to be_archived
      expect(former_child.reload).not_to be_archived
      expect(raw_parent_product_id(former_child)).to eq(former_parent.id) # existing data left untouched
    end

    it "no longer routes the children list or Archive family" do
      expect { Rails.application.routes.recognize_path("/inventory/products/#{former_parent.id}/children", method: :get) }
        .to raise_error(ActionController::RoutingError)
      expect { Rails.application.routes.recognize_path("/inventory/products/#{former_parent.id}/archive_family", method: :patch) }
        .to raise_error(ActionController::RoutingError)
    end

    it "the barcode lookup resolves a former parent like any product" do
      barcode = former_parent.product_barcodes.first&.barcode || former_parent.product_barcodes.create!(barcode: "FAM-BC").barcode
      get inventory_barcode_lookup_path(code: barcode), as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["id"]).to eq(former_parent.id)
    end
  end

  describe "inventory workflows" do
    it "receives, transfers, issues, counts and adjusts both former family members" do
      receive!(former_parent, central, 10)
      receive!(former_child, central, 4)

      transfer = business.stock_transfers.build(source_warehouse: central, destination_warehouse: branch_wh, transferred_on: Date.current)
      transfer.items.build(product: former_parent, quantity: 3)
      expect(Inventory::StockTransferPoster.new(transfer).call).to be_ok

      issue = business.stock_issues.build(warehouse: branch_wh, branch: branch_wh.branch, issued_on: Date.current)
      issue.items.build(product: former_parent, quantity: 1)
      expect(approve_and_post_stock_issue(issue)).to be_ok

      count = record_stock_count!(business: business, warehouse: central, counter: counter,
                                  lines: [ [ former_parent, 6 ], [ former_child, 4 ] ], complete: true)
      expect(approve_stock_count(count, approver)).to be_ok

      damaged = business.stock_adjustments.build(warehouse: central, adjusted_on: Date.current, reason: "damaged", created_by: owner)
      damaged.items.build(product: former_child, quantity_difference: -1)
      expect(Inventory::AdjustmentPoster.new(damaged).call).to be_ok

      expect([ on_hand(former_parent, central), on_hand(former_parent, branch_wh), on_hand(former_child, central) ]).to eq([ 6, 2, 3 ])
    end

    it "leaves existing stock, movements and documents unchanged" do
      receive!(former_parent, central, 10)
      receive!(former_child, central, 4)
      movements = InventoryMovement.order(:id).map(&:attributes)
      receipts  = GoodsReceipt.order(:id).map(&:attributes)

      [ inventory_products_path, inventory_product_path(former_parent), edit_inventory_product_path(former_parent),
        inventory_root_path, inventory_current_stock_report_path, inventory_low_stock_report_path ].each do |path|
        get path
        expect(response).to have_http_status(:ok), path
      end

      expect(InventoryMovement.order(:id).map(&:attributes)).to eq(movements)
      expect(GoodsReceipt.order(:id).map(&:attributes)).to eq(receipts)
      expect([ on_hand(former_parent, central), on_hand(former_child, central) ]).to eq([ 10, 4 ])
    end

    it "lists every product in reports — no family exclusion" do
      receive!(former_parent, central, 2)
      receive!(former_child, central, 3)
      rows = Inventory::Reports::CurrentStock.new(business).rows.to_h { |r| [ r.product, r.on_hand ] }
      expect(rows).to include(former_parent => 2, former_child => 3)
    end
  end
end
