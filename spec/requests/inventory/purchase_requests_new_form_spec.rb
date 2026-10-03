require "rails_helper"

# The general "إنشاء طلب شراء" form: any transactable product, with Low Stock
# offered only as an optional source of lines inside the form.
RSpec.describe "Purchase Request creation form", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Supplier 1") }
  let!(:main_wh)  { business.warehouses.create!(name: "Main WH") }
  let!(:other_wh) { business.warehouses.create!(name: "Other WH") }

  # Well stocked — never appears in Low Stock.
  let!(:stocked_product) do
    business.products.create!(name: "Stocked Shampoo", sku: "STK-1", average_cost_price: 20,
                               low_stock_level: 5, reorder_level: 5, reorder_quantity: 10)
  end
  # 1 on hand vs. reorder level 5 — appears in Low Stock.
  let!(:low_product) do
    business.products.create!(name: "Low Conditioner", sku: "LOW-1", average_cost_price: 30,
                               low_stock_level: 5, reorder_level: 5, reorder_quantity: 12)
  end

  before do
    { stocked_product => 50, low_product => 1 }.each do |product, qty|
      receipt = business.goods_receipts.build(warehouse: main_wh, received_on: Date.current)
      receipt.items.build(product: product, quantity: qty, unit_cost: product.average_cost_price)
      Inventory::GoodsReceiptPoster.new(receipt).call
    end
  end

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def line(product, qty:, price: 10, warehouse: main_wh)
    { product_id: product.id, quantity: qty, unit_price: price, source_warehouse_id: warehouse&.id }
  end

  def submit_form(lines, supplier_id: supplier.id, notes: nil, key: SecureRandom.uuid)
    post inventory_purchase_requests_path, params: {
      idempotency_key: key,
      purchase_request: {
        supplier_id: supplier_id, notes: notes,
        items_attributes: lines.each_with_index.to_h { |l, i| [ i.to_s, l ] }
      }
    }
  end

  describe "entry points" do
    it "the Purchase Requests page's create button opens the creation form, not the Low Stock section" do
      sign_in owner
      get inventory_purchase_requests_path

      expect(response.body).to include(%(href="#{new_inventory_purchase_request_path}"))
      expect(response.body).not_to include("low-stock-alerts")
    end

    it "GET new renders the form with every transactable product, low stock or not" do
      sign_in owner
      get new_inventory_purchase_request_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      product_select = doc.at_css("table.line-items-table select[name*='[product_id]']")
      option_ids = product_select.css("option").map { |o| o["value"] }.compact_blank
      expect(option_ids).to include(stocked_product.id.to_s, low_product.id.to_s)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.form.add_from_low_stock"))
      expect(doc.css("table.line-items-table tbody tr[data-line-row]").size).to eq(1)
      expect(doc.at_css("table.line-items-table [data-controller='searchable-select']")["data-searchable-select-floating-value"]).to eq("true")
      expect(doc.css("table.line-items-table input[name*='[notes]']")).to be_empty
      expect(doc.at_css("textarea[name='purchase_request[notes]']")).to be_present
    end

    it "makes the destination warehouse required, offering only the user's warehouses" do
      scoped = user_with("view_inventory", "create_purchase_requests")
      WarehouseAssignment.create!(user: scoped, warehouse: main_wh)
      sign_in scoped

      get new_inventory_purchase_request_path

      select = Nokogiri::HTML(response.body).at_css("table.line-items-table select[name*='[source_warehouse_id]']")
      expect(select["required"]).to be_present
      expect(select.css("option").map(&:text)).to include(main_wh.name)
      expect(select.css("option").map(&:text)).not_to include(other_wh.name, I18n.t("inventory.purchase_requests.form.no_warehouse"))
      # The only accessible warehouse is preselected.
      expect(select.at_css("option[selected]")["value"]).to eq(main_wh.id.to_s)
    end

    it "the Low Stock picker lists only Low Stock rows, from the existing report" do
      sign_in owner
      get new_inventory_purchase_request_path

      picker_ids = Nokogiri::HTML(response.body).css("[data-low-stock-row]").map { |r| r["data-product-id"] }
      expected   = Inventory::Reports::LowStock.new(business).rows.map { |r| r.product.id.to_s }
      expect(picker_ids).to eq(expected)
      expect(picker_ids).to include(low_product.id.to_s)
      expect(picker_ids).not_to include(stocked_product.id.to_s)
    end

    it "the Low Stock picker respects the user's warehouse scope" do
      scoped = user_with("view_inventory", "create_purchase_requests")
      WarehouseAssignment.create!(user: scoped, warehouse: other_wh)
      sign_in scoped

      get new_inventory_purchase_request_path

      expect(Nokogiri::HTML(response.body).css("[data-low-stock-row]")).to be_empty
    end

    it "is denied to a user without create permission" do
      sign_in user_with("view_inventory")
      get new_inventory_purchase_request_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST from the form" do
    it "creates a request for a product that is NOT low stock" do
      sign_in owner

      expect { submit_form([ line(stocked_product, qty: 10, warehouse: main_wh) ]) }
        .to change(PurchaseRequest, :count).by(1)

      request = PurchaseRequest.last
      expect(request.items.map(&:product)).to eq([ stocked_product ])
      expect(request).to be_draft
      expect(request.source).to be_nil
      expect(response).to redirect_to(inventory_purchase_requests_path(created_ids: request.id.to_s))
    end

    it "creates a request for a product picked from Low Stock" do
      sign_in owner
      submit_form([ line(low_product, qty: 12, warehouse: main_wh) ])

      expect(PurchaseRequest.last.items.map(&:product)).to eq([ low_product ])
    end

    it "mixes low-stock and normal products in one request, with notes on the request itself" do
      sign_in owner

      submit_form([ line(stocked_product, qty: 10), line(low_product, qty: 20) ], notes: "monthly order")

      request = PurchaseRequest.last
      expect(PurchaseRequest.count).to eq(1)
      expect(request.items.map(&:product)).to contain_exactly(stocked_product, low_product)
      expect(request.notes).to eq("monthly order")
      expect(request.items.map(&:notes)).to all(be_nil)
      expect(request.supplier).to eq(supplier)
    end

    it "ignores blank rows (no product chosen)" do
      sign_in owner
      submit_form([ line(stocked_product, qty: 3), { product_id: "", quantity: "", unit_price: "" } ])

      expect(PurchaseRequest.last.items.size).to eq(1)
    end

    it "rejects the same product twice for the same warehouse and re-renders the form with the input kept" do
      sign_in owner

      expect {
        submit_form([ line(low_product, qty: 12, warehouse: main_wh), line(low_product, qty: 5, warehouse: main_wh) ])
      }.not_to change(PurchaseRequest, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.duplicate_product"))
      expect(Nokogiri::HTML(response.body).css("table.line-items-table tbody tr[data-line-row]").size).to eq(2)
    end

    it "rejects a line with no warehouse" do
      sign_in owner

      expect { submit_form([ line(stocked_product, qty: 1, warehouse: nil) ]) }.not_to change(PurchaseRequest, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.missing_warehouse"))
    end

    it "rejects an inactive warehouse" do
      main_wh.update!(status: "inactive")
      sign_in owner

      expect { submit_form([ line(stocked_product, qty: 1) ]) }.not_to change(PurchaseRequest, :count)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))
    end

    it "keeps the Low Stock review modal's warehouse-less total-stock lines working" do
      sign_in owner

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid,
          items: [ { product_id: low_product.id, quantity: 12, unit_price: 30, supplier_id: supplier.id } ]
        }
      }.to change(PurchaseRequest, :count).by(1)
      expect(PurchaseRequest.last.items.first.source_warehouse_id).to be_nil
    end

    it "rejects non-positive quantities" do
      sign_in owner
      expect { submit_form([ line(stocked_product, qty: 0) ]) }.not_to change(PurchaseRequest, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "requires a supplier" do
      sign_in owner
      expect { submit_form([ line(stocked_product, qty: 1) ], supplier_id: "") }.not_to change(PurchaseRequest, :count)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.missing_supplier"))
    end

    it "does not create duplicates when the same idempotency key is resubmitted" do
      sign_in owner
      key = SecureRandom.uuid
      submit_form([ line(stocked_product, qty: 1) ], key: key)
      expect { submit_form([ line(stocked_product, qty: 1) ], key: key) }.not_to change(PurchaseRequest, :count)
    end

    it "is denied to a user without create permission" do
      sign_in user_with("view_inventory")
      expect { submit_form([ line(stocked_product, qty: 1) ]) }.not_to change(PurchaseRequest, :count)
      expect(response).to redirect_to(root_path)
    end

    it "allows a create_purchase_requests user to request a product regardless of stock level" do
      sign_in user_with("view_inventory", "create_purchase_requests")
      expect { submit_form([ line(stocked_product, qty: 1) ]) }.to change(PurchaseRequest, :count).by(1)
    end
  end

  describe "server-side scope enforcement (direct requests bypassing the UI)" do
    let(:foreign_business) { create(:business) }

    it "rejects another business's product" do
      foreign = foreign_business.products.create!(name: "Foreign", sku: "F-1", average_cost_price: 5)
      sign_in owner

      expect { submit_form([ line(foreign, qty: 1) ]) }.not_to change(PurchaseRequest, :count)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.invalid_product"))
    end

    it "rejects an archived product and a nonexistent product id" do
      archived = business.products.create!(name: "Old", sku: "OLD-1", average_cost_price: 5, active: false)
      sign_in owner

      expect { submit_form([ line(archived, qty: 1) ]) }.not_to change(PurchaseRequest, :count)
      expect {
        submit_form([ { product_id: 999_999, quantity: 1, unit_price: 1 } ])
      }.not_to change(PurchaseRequest, :count)
    end

    it "rejects a warehouse outside a scoped user's assignments" do
      scoped = user_with("view_inventory", "create_purchase_requests")
      WarehouseAssignment.create!(user: scoped, warehouse: main_wh)
      sign_in scoped

      expect { submit_form([ line(stocked_product, qty: 1, warehouse: other_wh) ]) }.not_to change(PurchaseRequest, :count)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))

      expect { submit_form([ line(stocked_product, qty: 1, warehouse: main_wh) ]) }.to change(PurchaseRequest, :count).by(1)
    end

    it "rejects another business's warehouse" do
      foreign_wh = foreign_business.warehouses.create!(name: "Foreign WH")
      sign_in owner

      expect { submit_form([ line(stocked_product, qty: 1, warehouse: foreign_wh) ]) }.not_to change(PurchaseRequest, :count)
    end

    it "applies the same guards to the Low Stock review modal's items[] payload" do
      scoped = user_with("view_inventory", "create_purchase_requests")
      WarehouseAssignment.create!(user: scoped, warehouse: main_wh)
      sign_in scoped

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid,
          items: [ { product_id: low_product.id, quantity: 1, unit_price: 1, supplier_id: supplier.id,
                     source_warehouse_id: other_wh.id } ]
        }
      }.not_to change(PurchaseRequest, :count)
      expect(response).to redirect_to(inventory_root_path)
    end
  end

  it "leaves the Low Stock calculation unchanged by creating a request (no stock movement)" do
    sign_in owner
    before_rows = Inventory::Reports::LowStock.new(business).rows.map { |r| [ r.product.id, r.on_hand, r.suggested_quantity ] }

    submit_form([ line(low_product, qty: 12, warehouse: main_wh) ])

    after_rows = Inventory::Reports::LowStock.new(business).rows.map { |r| [ r.product.id, r.on_hand, r.suggested_quantity ] }
    expect(after_rows).to eq(before_rows)
  end
end
