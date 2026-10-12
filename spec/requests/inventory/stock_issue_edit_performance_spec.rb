require "rails_helper"

# Stock issue edit/update must not run queries per line item or per catalog
# product: the form lists every product once per line-item row, and used to
# look up each product's barcode with one or two queries per row (thousands of
# queries for a realistic issue).
RSpec.describe "Inventory::StockIssues edit performance", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "B", active: true) }

  def products!(count, offset: 0)
    Array.new(count) do |i|
      business.products.create!(name: "P#{offset + i}", sku: "SKU-#{offset + i}", initial_cost_price: 10, average_cost_price: 10)
              .tap { |p| p.product_barcodes.create!(barcode: "EXTRA-#{offset + i}", is_primary: false) }
    end
  end

  def pending_issue(products)
    issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: owner)
    products.each { |p| issue.items.build(product: p, quantity: 1) }
    issue.save!
    Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: owner).call
    issue.reload
  end

  def update_params(issue, quantity:)
    items = issue.items.order(:id).each_with_index.to_h do |item, i|
      [ i.to_s, { id: item.id, product_id: item.product_id, quantity: quantity } ]
    end
    { lock_token: issue.reload.lock_token,
      stock_issue: { warehouse_id: warehouse.id, branch_id: branch.id, issued_on: Date.current, items_attributes: items } }
  end

  # One request first, so per-session/per-request warm-up (current user,
  # layout attachments) isn't counted against the first measured action.
  before do
    sign_in owner
    get inventory_stock_issues_path
  end

  it "renders the edit form with a constant number of queries, whatever the item and product counts" do
    small = pending_issue(products!(2))
    small_count = count_queries { get edit_inventory_stock_issue_path(small) }

    big = pending_issue(products!(15, offset: 100))
    products!(30, offset: 200)
    big_count = count_queries { get edit_inventory_stock_issue_path(big) }

    expect(response).to have_http_status(:ok)
    expect(big_count).to eq(small_count)
  end

  it "re-renders an invalid update with a constant number of queries" do
    small = pending_issue(products!(2))
    small_count = count_queries { patch inventory_stock_issue_path(small), params: update_params(small, quantity: 0) }

    big = pending_issue(products!(15, offset: 100))
    big_count = count_queries { patch inventory_stock_issue_path(big), params: update_params(big, quantity: 0) }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(big_count).to eq(small_count)
  end

  it "saves an update with one write per changed line and no per-line reads" do
    small = pending_issue(products!(2))
    small_count = count_queries { patch inventory_stock_issue_path(small), params: update_params(small, quantity: 3) }

    big = pending_issue(products!(15, offset: 100))
    big_count = count_queries { patch inventory_stock_issue_path(big), params: update_params(big, quantity: 3) }

    expect(response).to have_http_status(:redirect)
    expect(big.reload.items.map { |i| i.quantity.to_i }.uniq).to eq([ 3 ])
    expect(big_count - small_count).to eq(15 - 2) # only the extra UPDATE per extra line
  end

  it "still renders each row's own product as selected, with the primary barcode" do
    products = products!(3)
    primary = products.first.product_barcodes.find_by(is_primary: true).barcode
    issue = pending_issue(products)

    get edit_inventory_stock_issue_path(issue)
    doc = Nokogiri::HTML(response.body)
    rows = doc.css("tbody[data-line-items-target='rows'] select")
    expect(rows.map { |s| s.at_css("option[selected]")&.[]("value") }).to eq(issue.items.order(:id).map { |i| i.product_id.to_s })
    option = rows.first.at_css("option[value='#{products.first.id}']")
    expect(option["data-barcode"]).to eq(primary)
    expect(doc.css("template select option[selected]")).to be_empty
  end

  it "still refuses a product family (parent product) on update" do
    products = products!(2)
    issue = pending_issue(products)
    parent = business.products.create!(name: "Family", sku: "FAM", initial_cost_price: 1, average_cost_price: 1)
    business.products.create!(name: "Child", sku: "FAM-1", initial_cost_price: 1, average_cost_price: 1, parent_product: parent)

    params = update_params(issue, quantity: 1)
    params[:stock_issue][:items_attributes]["9"] = { product_id: parent.id, quantity: 1 }
    patch inventory_stock_issue_path(issue), params: params

    expect(response).to have_http_status(:unprocessable_entity)
    expect(issue.reload.items.map(&:product_id)).not_to include(parent.id)
  end
end
