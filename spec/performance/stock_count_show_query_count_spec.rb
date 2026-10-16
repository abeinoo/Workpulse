require "rails_helper"

# Regression guard for the stock count show page. Its summary cards
# (StockCount#adjustment_value etc.) used to re-load the count's items and each
# product one by one, and every worksheet row's Product#barcode ran one or two
# more queries — so the page scaled with the number of counted products. It
# now loads the items association once (with products) for both, and resolves
# barcodes in one lookup; every displayed figure must stay the same.
RSpec.describe "Stock count show — query count and figures", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let!(:warehouse)  { business.warehouses.create!(name: "Main") }
  let!(:warehouse2) { business.warehouses.create!(name: "Annex") }

  def add_products(count)
    start = business.products.count
    Array.new(count) do |i|
      n = start + i
      business.products.create!(name: "Product #{format('%03d', n)}", sku: "SKU-#{n}",
                                initial_cost_price: 1, average_cost_price: BigDecimal("1.25") * (n + 1)).tap do |p|
        p.product_barcodes.create!(barcode: "EXTRA-#{n}", is_primary: false) if (n % 3).zero?
        p.product_barcodes.delete_all if (n % 5) == 4 # some products have no barcode at all
      end
    end
  end

  # Mixed rows: matched, shortages, overages, and uncounted.
  def stock_count(products, warehouse: self.warehouse, status: :completed)
    count = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: owner,
                                        status: status, completed_at: Time.current)
    products.each_with_index do |p, i|
      counted = case i % 4
      when 0 then 10
      when 1 then 7
      when 2 then 13
      end
      count.items.build(product: p, system_quantity: 10, counted_quantity: counted)
    end
    count.save!
    count
  end

  def queries_for(path)
    get path
    count_queries { get path }
  end

  before { sign_in owner }

  it "keeps the query count flat as the number of counted products grows" do
    small = queries_for(inventory_stock_count_path(stock_count(add_products(4))))
    large = queries_for(inventory_stock_count_path(stock_count(add_products(40))))

    expect(response).to have_http_status(:ok)
    expect(large).to eq(small)
    expect(large).to be <= 30
  end

  it "shows the same summary figures, adjustment value and rows as computed from fresh records" do
    count = stock_count(add_products(13))

    get inventory_stock_count_path(count)
    page = Nokogiri::HTML(response.body)

    fresh = StockCount.find(count.id) # nothing preloaded: the original per-record paths
    stats = page.css(".stat-card__value").map { |n| n.text.squish }
    expect(stats).to include("#{fresh.counted_products} / #{fresh.total_products} #{fresh.completion_percentage}%")
    expect(stats).to include(fresh.remaining_products.to_s, fresh.matched_count.to_s,
                             fresh.shortage_count.to_s, fresh.overage_count.to_s)
    expect(stats).to include(ActiveSupport::NumberHelper.number_to_currency(fresh.adjustment_value, unit: ""))
    expect(fresh.adjustment_value).not_to be_zero

    rows = page.css("table tbody tr").map { |tr| tr.css("td").map { |td| td.text.squish } }
    expected = fresh.items.map do |item|
      diff = item.difference.to_d
      [ "#{item.product.name} (#{item.product.sku})", item.product.barcode.presence || "—", item.system_quantity.to_i.to_s,
        item.counted? ? item.counted_quantity.to_i.to_s : "—", item.counted? ? "#{diff.positive? ? '+' : ''}#{diff.to_i}" : "—" ]
    end
    expect(rows).to eq(expected)
    expect(expected.map(&:second)).to include("—") # covers products with no barcode
  end

  it "shows the approved count's inventory impact from its adjustment" do
    count = stock_count(add_products(6))
    approver = create(:user, business: business).tap do |u|
      role = business.permission_roles.create!(name: "Approver", permissions: %w[view_inventory post_stock_counts])
      u.update_column(:permission_role_id, role.id)
    end
    Inventory::StockCountApprover.new(count, user: approver).call
    adjustment = count.reload.stock_adjustment

    get inventory_stock_count_path(count)

    expect(count).to be_approved
    expect(adjustment.net_value).not_to be_zero
    expect(response).to have_http_status(:ok)
    [ adjustment.shortage_value, adjustment.overage_value, adjustment.net_value ].each do |value|
      expect(response.body).to include(controller.view_context.format_currency(value))
    end
  end

  describe "scoping and authorization (unchanged)" do
    it "does not show another business's count" do
      other = create(:business)
      other_wh = other.warehouses.create!(name: "Theirs")
      other_count = other.stock_counts.build(warehouse: other_wh, counted_on: Date.current, status: :completed)
      other_count.items.build(product: other.products.create!(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1),
                              system_quantity: 1, counted_quantity: 1)
      other_count.save!

      get inventory_stock_count_path(other_count)

      expect(response).to have_http_status(:not_found)
    end

    it "hides a count in a warehouse the user is not assigned to" do
      count = stock_count(add_products(2), warehouse: warehouse2)
      scoped = create(:user, business: business).tap do |u|
        role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
        u.update_column(:permission_role_id, role.id)
        u.warehouse_assignments.create!(warehouse: warehouse)
      end
      sign_in scoped

      get inventory_stock_count_path(count)

      expect(response).to have_http_status(:not_found)
    end

    it "refuses a user without inventory permissions" do
      count = stock_count(add_products(2))
      sign_in create(:user, business: business)

      get inventory_stock_count_path(count)

      expect(response).to have_http_status(:redirect)
      expect(response.body).not_to include(count.count_number)
    end
  end
end
