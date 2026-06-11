require "rails_helper"

RSpec.describe "Inventory::StockCounts", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  let(:counter) do  # can create sessions and edit counts, but NOT approve
    role = business.permission_roles.create!(name: "Counter", permissions: %w[view_inventory manage_stock_counts])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:approver) do # can approve
    role = business.permission_roles.create!(name: "Approver", permissions: %w[view_inventory post_stock_counts])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", barcode: "111", initial_cost_price: 10, average_cost_price: 10)
  end

  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 20, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def start_session(as:)
    sign_in as
    post inventory_stock_counts_path, params: {
      stock_count: { warehouse_id: warehouse.id, counted_on: Date.current }
    }
    business.stock_counts.order(:id).last
  end

  def set_count(count, qty, as:)
    sign_in as
    item = count.items.first
    patch inventory_stock_count_path(count), params: {
      stock_count: { items_attributes: { "0" => { id: item.id, product_id: product.id, counted_quantity: qty } } }
    }
    count.reload
  end

  describe "session creation" do
    it "renders index and new" do
      sign_in owner
      get inventory_stock_counts_path
      expect(response).to have_http_status(:ok)
      get new_inventory_stock_count_path
      expect(response).to have_http_status(:ok)
    end

    it "preloads a row per product with snapshotted system quantity (status draft)" do
      count = start_session(as: counter)
      expect(count).to be_draft
      expect(count.items.size).to eq(business.products.count)
      expect(count.items.find_by(product: product).system_quantity).to eq(20)
    end

    it "renders the counting screen with the scanner, progress and filters" do
      count = start_session(as: counter)
      sign_in counter
      get edit_inventory_stock_count_path(count)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="line-items count-sheet"')
      expect(response.body).to include('data-barcode-scanner-mode-value="rows"')
      expect(response.body).to include('data-count-sheet-target="progressBar"')
      expect(response.body).to include('data-filter="not_counted"')
    end
  end

  describe "counting → completion → approval" do
    it "moves to in_progress on the first saved count and computes the difference" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      expect(count).to be_in_progress
      item = count.items.first
      expect(item.system_quantity).to eq(20)
      expect(item.difference).to eq(-3)
    end

    it "counter completes, approver approves → adjustment corrects stock" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)

      sign_in counter
      patch complete_inventory_stock_count_path(count)
      expect(count.reload).to be_completed

      sign_in approver
      patch approve_inventory_stock_count_path(count)
      expect(response).to redirect_to(inventory_stock_count_path(count))
      expect(count.reload).to be_approved
      expect(product.reload.current_stock).to eq(17)
      expect(count.stock_adjustment).to be_present
      expect(count.stock_adjustment.reason).to eq("stock_count")
    end

    it "lets an approver send a completed count back (reopen)" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      sign_in counter
      patch complete_inventory_stock_count_path(count)

      sign_in approver
      patch reopen_inventory_stock_count_path(count)
      expect(count.reload).to be_in_progress
    end
  end

  describe "segregation of duties (employees cannot approve)" do
    it "forbids a counter from approving a completed count" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      sign_in counter
      patch complete_inventory_stock_count_path(count)

      patch approve_inventory_stock_count_path(count)   # counter lacks post_stock_counts
      expect(response).to redirect_to(root_path)
      expect(count.reload).to be_completed
    end

    it "cannot approve before completion" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)   # in_progress, not completed
      sign_in approver
      patch approve_inventory_stock_count_path(count)
      expect(response).to redirect_to(root_path)
      expect(count.reload).to be_in_progress
    end

    it "forbids editing an approved count" do
      count = start_session(as: owner)
      set_count(count, 17, as: owner)
      sign_in owner
      patch complete_inventory_stock_count_path(count)
      patch approve_inventory_stock_count_path(count)

      set_count(count, 5, as: owner)
      expect(count.reload.items.first.counted_quantity).to eq(17)
    end
  end

  describe "approval with uncounted products" do
    let!(:other) { business.products.create!(name: "Conditioner", sku: "CN-1", initial_cost_price: 4, average_cost_price: 4) }

    before do  # give "other" real stock so we'd notice if approval touched it
      r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      r.items.build(product: other, quantity: 9, unit_cost: 4)
      Inventory::GoodsReceiptPoster.new(r).call
    end

    it "approves, skipping uncounted products without affecting their stock" do
      count = start_session(as: counter)                  # preloads product + other (both blank)
      item  = count.items.find_by(product: product)
      sign_in counter
      patch inventory_stock_count_path(count), params: {  # count only one of the two products
        stock_count: { items_attributes: { "0" => { id: item.id, product_id: product.id, counted_quantity: 17 } } }
      }
      patch complete_inventory_stock_count_path(count)
      expect(count.reload).to be_completed

      sign_in approver
      patch approve_inventory_stock_count_path(count)
      expect(count.reload).to be_approved
      expect(product.reload.current_stock).to eq(17)      # counted product corrected
      expect(other.reload.current_stock).to eq(9)         # uncounted product untouched
      # no adjustment line for the uncounted product
      expect(count.stock_adjustment.items.map(&:product)).to eq([ product ])
    end
  end

  describe "CSV export" do
    it "exports product, barcode, sku, system, counted and difference" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)

      sign_in counter
      get export_inventory_stock_count_path(count, format: :csv)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      expect(response.body).to include("Product,Barcode,SKU,System Quantity,Counted Quantity,Difference")
      expect(response.body).to include("Shampoo,111,SH-1,20,17,-3")
    end
  end

  describe "report figures" do
    it "summarises matched / shortage / overage counts and adjustment value" do
      other = business.products.create!(name: "Conditioner", sku: "CN-1", initial_cost_price: 4, average_cost_price: 4)
      count = start_session(as: counter)
      count.items.find_by(product: product).update!(counted_quantity: 17)  # -3 shortage
      count.items.find_by(product: other).update!(counted_quantity: 2)     # +2 overage (system 0)

      expect(count.shortage_count).to eq(1)
      expect(count.overage_count).to eq(1)
      expect(count.matched_count).to eq(0)
      # (-3 * 10) + (2 * 4) = -22
      expect(count.adjustment_value).to eq(-22)
    end
  end

  describe "count ⇄ adjustment navigation" do
    it "links between the approved count and its generated adjustment, both ways" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      sign_in counter
      patch complete_inventory_stock_count_path(count)
      sign_in approver
      patch approve_inventory_stock_count_path(count)
      adj = count.reload.stock_adjustment
      expect(adj).to be_present

      # Adjustment → source count
      get inventory_stock_adjustment_path(adj)
      expect(response.body).to include(count.count_number)
      expect(response.body).to include(inventory_stock_count_path(count))

      # Count → adjustment, plus the value-impact section
      get inventory_stock_count_path(count)
      expect(response.body).to include(adj.adjustment_number)
      expect(response.body).to include(inventory_stock_adjustment_path(adj))
      expect(response.body).to include(I18n.t("inventory.stock_counts.impact.title"))
    end
  end
end
