require "rails_helper"

# Query-count regression guard for the inventory document product pickers.
# Every line row lists the whole catalog; the original per-product helper
# (#inventory_product_options -> Product#barcode) ran one or two barcode
# queries per product per row, so these pages scaled with products x rows.
# The batched path (one Product.barcode_lookup, options rendered once, each
# row marking its selection) must keep the query count flat as both grow —
# while rendering exactly the markup the per-product helper produced.
RSpec.describe "Inventory product pickers — query count scaling", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let!(:warehouse)  { business.warehouses.create!(name: "Main") }
  let!(:warehouse2) { business.warehouses.create!(name: "Annex") }
  let(:branch)    { business.branches.create!(name: "Downtown", active: true) }

  before { sign_in owner }

  # Products get an auto-generated primary barcode on create; every 3rd also
  # gets a second, non-primary one, so both lookup rules are exercised.
  def add_products(count)
    start = business.products.count
    Array.new(count) do |i|
      n = start + i
      business.products.create!(name: "Product #{format('%03d', n)}", sku: "SKU-#{n}",
                                initial_cost_price: 1, average_cost_price: 1).tap do |p|
        p.product_barcodes.create!(barcode: "EXTRA-#{n}", is_primary: false) if (n % 3).zero?
      end
    end
  end

  def queries_for(path)
    get path # warm-up: templates, schema cache
    count_queries { get path }
  end

  # The markup the original per-product helper renders for one row.
  def reference_options(products, selected_id)
    ApplicationController.helpers.inventory_product_options(Product.where(id: products.map(&:id)).order(:name).to_a, selected_id)
  end

  def transactable
    business.products.transactable.ordered.to_a
  end

  def draft_receipt(lines)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            funding_source_kind: "company_cash", created_by: owner)
    lines.each { |p| receipt.items.build(product: p, quantity: 1, unit_cost: 2) }
    receipt.save!
    receipt
  end

  describe "new document forms" do
    {
      "goods receipt"    => -> { new_inventory_goods_receipt_path },
      "purchase request" => -> { new_inventory_purchase_request_path },
      "stock transfer"   => -> { new_inventory_stock_transfer_path }
    }.each do |label, path|
      it "keeps the #{label} form's query count flat as the catalog grows" do
        add_products(3)
        small = queries_for(instance_exec(&path))

        add_products(30)
        large = queries_for(instance_exec(&path))

        expect(response).to have_http_status(:ok)
        expect(large).to eq(small)
        expect(large).to be <= 30
        expect(response.body).to include(reference_options(transactable, nil))
      end
    end
  end

  describe "goods receipt edit" do
    it "keeps the query count flat as the catalog and the number of lines grow" do
      add_products(4)
      receipt = draft_receipt(transactable.first(2))
      small = queries_for(edit_inventory_goods_receipt_path(receipt))

      add_products(30)
      transactable.last(10).each { |p| receipt.items.create!(product: p, quantity: 1, unit_cost: 2) }
      large = queries_for(edit_inventory_goods_receipt_path(receipt))

      expect(response).to have_http_status(:ok)
      expect(large).to eq(small)
      expect(large).to be <= 30
    end

    it "renders each line's options exactly as the per-product helper did, with its product selected" do
      add_products(8)
      receipt = draft_receipt(transactable.values_at(0, 3, 6))

      get edit_inventory_goods_receipt_path(receipt)

      receipt.items.each do |item|
        expect(response.body).to include(reference_options(transactable, item.product_id))
      end
      expect(response.body).to include(reference_options(transactable, nil)) # new-row template
    end
  end

  describe "goods receipt created from a purchase request" do
    def approved_request(products)
      pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
      products.each { |p| pr.items.build(product: p, quantity: 5, unit_price: 3, source_warehouse: warehouse) }
      pr.save!
      pr.update_columns(status: "pending_approval", submitted_by_id: owner.id)
      Inventory::PurchaseRequestApproval.new(purchase_request_id: pr.id, actor: owner).approve!
      pr.reload
    end

    # SQL statements run by one request, by kind.
    def queries_by_kind(path)
      get path # warm-up
      kinds = Hash.new(0)
      counter = lambda do |*, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        sql = payload[:sql]
        kind = if sql.match?(/FROM "product(s|_barcodes)"/) then :picker
        elsif sql.include?('SUM("goods_receipt_items"."quantity")') then :received_quantity
        else :other
        end
        kinds[kind] += 1
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path }
      kinds
    end

    it "keeps the request-line pickers' product/barcode queries flat as lines grow, rendering each line's own product" do
      add_products(12)
      small_pr = approved_request(transactable.first(2))
      large_pr = approved_request(transactable.first(10))
      small = queries_by_kind(new_inventory_goods_receipt_path(purchase_request_id: small_pr.id))
      large = queries_by_kind(new_inventory_goods_receipt_path(purchase_request_id: large_pr.id))

      expect(response).to have_http_status(:ok)
      expect(large[:picker]).to eq(small[:picker])
      expect(large[:other]).to eq(small[:other])
      # The only per-line query left is each request line's "received so far"
      # hint (PurchaseRequestItem#received_quantity) — outside the picker.
      expect(large[:received_quantity]).to eq(10)
      large_pr.items.each do |line|
        expect(response.body).to include(reference_options([ line.product ], line.product_id))
      end
    end

    it "still renders a request line whose product is no longer transactable (with its barcode)" do
      add_products(3)
      archived = transactable.first
      pr = approved_request([ archived ])
      archived.update!(active: false)

      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(response.body).to include(reference_options([ archived ], archived.id))
      expect(response.body).to include(%(data-barcode="#{archived.barcode}")) if archived.barcode
    end
  end

  describe "stock issue import — unknown SKU rows" do
    def batch_with_unknown_rows(count)
      issue = business.stock_issues.create!(warehouse: warehouse, branch: branch, issued_on: Date.current, status: :draft)
      batch = StockIssueImportBatch.create!(business: business, warehouse: warehouse, branch: branch,
                                            stock_issue: issue, status: :draft, created_by: owner)
      count.times { |i| batch.rows.create!(row_number: i + 2, sku: "UNKNOWN-#{i}", quantity: 1, status: :pending, failure_reason: "unknown_sku") }
      batch
    end

    it "keeps the query count flat as unknown rows and the catalog grow" do
      add_products(3)
      small = queries_for(inventory_stock_issue_import_batch_path(batch_with_unknown_rows(1)))

      add_products(30)
      large_batch = batch_with_unknown_rows(8)
      large = queries_for(inventory_stock_issue_import_batch_path(large_batch))

      expect(response).to have_http_status(:ok)
      expect(large).to eq(small)
      expect(response.body.scan(reference_options(transactable, nil)).size).to eq(8)
    end
  end
end
