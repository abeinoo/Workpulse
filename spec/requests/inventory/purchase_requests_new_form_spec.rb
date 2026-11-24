require "rails_helper"

# The general "إنشاء طلب شراء" form: any transactable product, with Low Stock
# offered only as an optional source of lines inside the form.
RSpec.describe "Purchase Request creation form", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Supplier 1") }
  let!(:main_wh)  { business.warehouses.create!(name: "Main WH") }
  let!(:other_wh) { business.warehouses.create!(name: "Other WH") }
  let!(:responsible) { purchaser_with_custody(business, first_name: "Rami") }

  # Well stocked — never appears in Low Stock.
  let!(:stocked_product) do
    business.products.create!(name: "Stocked Shampoo", sku: "STK-1", average_cost_price: 20)
  end
  # 1 on hand vs. Main WH's threshold 5 — appears in Low Stock.
  let!(:low_product) do
    business.products.create!(name: "Low Conditioner", sku: "LOW-1", average_cost_price: 30)
  end

  before do
    { stocked_product => 10, low_product => 12 }.each do |product, reorder|
      ProductWarehouseSetting.create!(product: product, warehouse: main_wh, low_stock_level: 5, reorder_quantity: reorder)
    end
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

  def line(product, qty:, price: 10, supplier: self.supplier)
    { product_id: product.id, quantity: qty, unit_price: price, supplier_id: supplier&.id }
  end

  def submit_form(lines, warehouse: main_wh, notes: nil, key: SecureRandom.uuid, responsible_employee: responsible)
    post inventory_purchase_requests_path, params: {
      idempotency_key: key,
      purchase_request: {
        warehouse_id: warehouse&.id, notes: notes, responsible_employee_id: responsible_employee&.id,
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
      # The line's product picker searches every transactable product on demand
      # (no catalogue in the page) — product_search returns both.
      picker = doc.at_css("table.line-items-table [data-controller='product-combobox']")
      expect(picker["data-product-combobox-kind-value"]).to eq("transactable")
      expect(picker.css("select[name*='[product_id]'] option").map { |o| o["value"] }.compact_blank).to be_empty
      get inventory_product_search_path(kind: "transactable")
      expect(response.parsed_body.map { |p| p["id"] }).to include(stocked_product.id, low_product.id)
      get new_inventory_purchase_request_path
      expect(response.body).to include(I18n.t("inventory.purchase_requests.form.add_from_low_stock"))
      expect(doc.css("table.line-items-table tbody tr[data-line-row]").size).to eq(1)
      expect(doc.css("table.line-items-table input[name*='[notes]']")).to be_empty
      expect(doc.at_css("textarea[name='purchase_request[notes]']")).to be_present
    end

    it "asks for ONE required warehouse in the request details, offering only the user's warehouses" do
      scoped = user_with("view_inventory", "create_purchase_requests")
      WarehouseAssignment.create!(user: scoped, warehouse: main_wh)
      sign_in scoped

      get new_inventory_purchase_request_path

      doc = Nokogiri::HTML(response.body)
      select = doc.at_css("select[name='purchase_request[warehouse_id]']")
      expect(select["required"]).to be_present
      expect(select.css("option").map(&:text)).to include(main_wh.name)
      expect(select.css("option").map(&:text)).not_to include(other_wh.name)
      # The only accessible warehouse is preselected.
      expect(select.at_css("option[selected]")["value"]).to eq(main_wh.id.to_s)
      # No per-line warehouse any more.
      expect(doc.css("table.line-items-table select[name*='warehouse_id']")).to be_empty
    end

    it "moves the supplier to each line: no request-level supplier, an optional supplier select per row" do
      sign_in owner
      supplier
      get new_inventory_purchase_request_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('select[name="purchase_request[supplier_id]"]')).to be_nil
      row_select = doc.at_css("table.line-items-table select[name*='[supplier_id]'][data-supplier-field]")
      expect(row_select).to be_present
      expect(row_select["required"]).to be_nil
      expect(row_select.at_css('option[value=""]').text).to include(I18n.t("inventory.purchase_requests.no_supplier"))
      expect(row_select.css("option").map(&:text)).to include(supplier.name)
    end

    it "carries each product's default supplier in the picker's search results, for the per-line prefill" do
      stocked_product.update!(default_supplier: supplier)
      sign_in owner
      get inventory_product_search_path(kind: "transactable")

      by_id = response.parsed_body.index_by { |p| p["id"] }
      expect(by_id[stocked_product.id]["default_supplier_id"]).to eq(supplier.id)
      expect(by_id[low_product.id]["default_supplier_id"]).to be_nil
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

      expect { submit_form([ line(stocked_product, qty: 10) ]) }
        .to change(PurchaseRequest, :count).by(1)

      request = PurchaseRequest.last
      expect(request.items.map(&:product)).to eq([ stocked_product ])
      expect(request).to be_draft
      expect(request.source).to be_nil
      expect(response).to redirect_to(inventory_purchase_requests_path(created_ids: request.id.to_s))
    end

    it "creates a request for a product picked from Low Stock" do
      sign_in owner
      submit_form([ line(low_product, qty: 12) ])

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
      expect(request.items.map(&:supplier)).to all(eq(supplier))
      expect(request.supplier).to be_nil
    end

    it "creates ONE request with one warehouse for products of several suppliers" do
      other_supplier = business.suppliers.create!(name: "Supplier 2")
      sign_in owner

      expect {
        submit_form([ line(stocked_product, qty: 1, supplier: supplier), line(low_product, qty: 2, supplier: other_supplier) ])
      }.to change(PurchaseRequest, :count).by(1)

      request = PurchaseRequest.last
      expect(request.warehouse).to eq(main_wh)
      expect(request.items.map { |i| [ i.product, i.supplier ] })
        .to contain_exactly([ stocked_product, supplier ], [ low_product, other_supplier ])
      expect(request.items.map(&:source_warehouse_id)).to all(be_nil)
    end

    it "keeps a manually overridden line supplier without changing the product's default supplier" do
      other_supplier = business.suppliers.create!(name: "Supplier 2")
      stocked_product.update!(default_supplier: supplier)
      sign_in owner

      submit_form([ line(stocked_product, qty: 1, supplier: other_supplier) ])

      expect(PurchaseRequest.last.items.sole.supplier).to eq(other_supplier)
      expect(stocked_product.reload.default_supplier).to eq(supplier)
    end

    it "ignores blank rows (no product chosen)" do
      sign_in owner
      submit_form([ line(stocked_product, qty: 3), { product_id: "", quantity: "", unit_price: "" } ])

      expect(PurchaseRequest.last.items.size).to eq(1)
    end

    it "rejects the same product twice (even under different suppliers) and re-renders the form with the input kept" do
      sign_in owner

      expect {
        submit_form([ line(low_product, qty: 12), line(low_product, qty: 5, supplier: nil) ])
      }.not_to change(PurchaseRequest, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.duplicate_product"))
      expect(Nokogiri::HTML(response.body).css("table.line-items-table tbody tr[data-line-row]").size).to eq(2)
    end

    it "rejects a request with no warehouse" do
      sign_in owner

      expect { submit_form([ line(stocked_product, qty: 1) ], warehouse: nil) }.not_to change(PurchaseRequest, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.missing_warehouse"))
    end

    it "rejects an inactive warehouse" do
      main_wh.update!(status: "inactive")
      sign_in owner

      expect { submit_form([ line(stocked_product, qty: 1) ]) }.not_to change(PurchaseRequest, :count)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))
    end

    it "refuses a Low Stock review modal line left without a warehouse (total-stock alert)" do
      sign_in owner

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
          items: [ { product_id: low_product.id, quantity: 12, unit_price: 30, supplier_id: supplier.id } ]
        }
      }.not_to change(PurchaseRequest, :count)
      expect(flash[:alert]).to eq(I18n.t("inventory.purchase_requests.errors.missing_warehouse"))
    end

    it "rejects non-positive quantities" do
      sign_in owner
      expect { submit_form([ line(stocked_product, qty: 0) ]) }.not_to change(PurchaseRequest, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "creates a draft line without a supplier when none is chosen (product without a default supplier)" do
      sign_in owner
      expect { submit_form([ line(stocked_product, qty: 1, supplier: nil) ]) }.to change(PurchaseRequest, :count).by(1)

      request = PurchaseRequest.last
      expect(request.items.sole.supplier_id).to be_nil
      expect(request).to be_draft
      expect(request.warehouse).to eq(main_wh)
    end

    it "rejects a line supplier that doesn't belong to the business" do
      sign_in owner
      foreign = create(:business).suppliers.create!(name: "Foreign")

      expect { submit_form([ line(stocked_product, qty: 1, supplier: foreign) ]) }.not_to change(PurchaseRequest, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.invalid_supplier"))
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

      expect { submit_form([ line(stocked_product, qty: 1) ], warehouse: other_wh) }.not_to change(PurchaseRequest, :count)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))

      expect { submit_form([ line(stocked_product, qty: 1) ], warehouse: main_wh) }.to change(PurchaseRequest, :count).by(1)
    end

    it "rejects another business's warehouse" do
      foreign_wh = foreign_business.warehouses.create!(name: "Foreign WH")
      sign_in owner

      expect { submit_form([ line(stocked_product, qty: 1) ], warehouse: foreign_wh) }.not_to change(PurchaseRequest, :count)
    end

    it "applies the same guards to the Low Stock review modal's items[] payload" do
      scoped = user_with("view_inventory", "create_purchase_requests")
      WarehouseAssignment.create!(user: scoped, warehouse: main_wh)
      sign_in scoped

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
          items: [ { product_id: low_product.id, quantity: 1, unit_price: 1, supplier_id: supplier.id,
                     warehouse_id: other_wh.id } ]
        }
      }.not_to change(PurchaseRequest, :count)
      expect(response).to redirect_to(inventory_root_path)
    end
  end

  it "leaves the Low Stock calculation unchanged by creating a request (no stock movement)" do
    sign_in owner
    before_rows = Inventory::Reports::LowStock.new(business).rows.map { |r| [ r.product.id, r.on_hand, r.suggested_quantity ] }

    submit_form([ line(low_product, qty: 12) ])

    after_rows = Inventory::Reports::LowStock.new(business).rows.map { |r| [ r.product.id, r.on_hand, r.suggested_quantity ] }
    expect(after_rows).to eq(before_rows)
  end
end
