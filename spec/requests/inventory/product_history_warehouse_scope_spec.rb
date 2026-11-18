require "rails_helper"

# Warehouse Architecture PR 5 (D6): the product page's purchase history
# (receipts, suppliers, prices, the last purchase price) and consumption
# statistics only reflect warehouses the viewer can reach.
RSpec.describe "Inventory::Products#show — history scoped by warehouse", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:mine)    { business.warehouses.create!(name: "Mine") }
  let!(:theirs)  { business.warehouses.create!(name: "Theirs") }
  let!(:branch)  { create(:branch, business: business, branch_type: "sales") }
  let!(:alpha)   { business.suppliers.create!(name: "Alpha Supplies") }
  let!(:beta)    { business.suppliers.create!(name: "Beta Traders") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 5) }

  before do
    receive!(mine, alpha, quantity: 20, unit_cost: 11, days_ago: 10)
    receive!(theirs, beta, quantity: 80, unit_cost: 97, days_ago: 2) # the latest receipt overall
    consume!(mine, 3)
    consume!(theirs, 50)
  end

  def receive!(warehouse, supplier, quantity:, unit_cost:, days_ago:)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current - days_ago)
    receipt.items.build(product: product, quantity: quantity, unit_cost: unit_cost)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
  end

  def consume!(warehouse, quantity)
    InventoryMovement.create!(business: business, product: product, warehouse: warehouse, branch: branch, direction: :out,
                              reason: :stock_issue, quantity: quantity, unit_cost: 5, occurred_on: Date.current)
  end

  def restricted_to(*warehouses)
    user_with_stock_permissions(business, :view_inventory).tap do |user|
      warehouses.each { |w| WarehouseAssignment.create!(user: user, warehouse: w) }
    end
  end

  def page_for(user)
    sign_in user
    get inventory_product_path(product)
    expect(response).to have_http_status(:ok)
    CGI.unescapeHTML(response.body)
  end

  # The value shown next to a detail-list label.
  def detail(body, key) = body[%r{<dt>#{Regexp.escape(I18n.t("inventory.products.#{key}"))}</dt>\s*<dd>(.*?)</dd>}m, 1]&.strip

  it "shows a restricted user only their warehouse's purchases, suppliers and prices" do
    body = page_for(restricted_to(mine))

    expect(body).to include("Alpha Supplies", "SAR 11.00")
    expect(body).not_to include("Beta Traders")
    expect(body).not_to include("97.00") # neither in the supplier rows nor as the last purchase price
  end

  it "computes consumption from their warehouses only" do
    body = page_for(restricted_to(mine))

    expect(detail(body, "consumed_this_month")).to eq("3")
  end

  it "shows a user with an empty access set no warehouse-specific history" do
    user = restricted_to(mine)
    allow_any_instance_of(User).to receive(:inventory_warehouse_ids).and_return([])
    body = page_for(user)

    expect(body).not_to include("Alpha Supplies", "Beta Traders", "SAR 11.00", "97.00")
    # No reachable receipt -> the purchase/consumption section is not rendered at all.
    expect(detail(body, "consumed_this_month")).to be_nil
    expect(body).not_to include(I18n.t("inventory.products.consumption_stats"))
  end

  it "keeps the whole business for the owner" do
    body = page_for(owner)

    expect(body).to include("Alpha Supplies", "Beta Traders", "SAR 97.00")
    expect(detail(body, "consumed_this_month")).to eq("53")
  end

  it "keeps the whole business for an access_all_warehouses holder" do
    body = page_for(user_with_stock_permissions(business, :view_inventory, :access_all_warehouses))

    expect(body).to include("Alpha Supplies", "Beta Traders")
    expect(detail(body, "consumed_this_month")).to eq("53")
  end

  it "does not change stock or history (read-only page)" do
    expect { page_for(restricted_to(mine)) }.not_to change { [ InventoryMovement.count, GoodsReceipt.count, product.reload.average_cost_price ] }
  end
end
