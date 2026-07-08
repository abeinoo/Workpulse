require "rails_helper"

RSpec.describe "Inventory::StockIssueImportBatches", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:branch)     { business.branches.create!(name: "Main Branch", active: true) }
  let!(:product) do
    business.products.create!(name: "Widget", sku: "W-001", initial_cost_price: 10, average_cost_price: 10)
  end

  before do
    sign_in owner
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def run_import(csv)
    file = Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "import.csv")
    post run_import_inventory_stock_issues_path,
         params: { file: file, warehouse_id: warehouse.id, branch_id: branch.id }
  end

  it "imports clean rows immediately and redirects straight to the issue when nothing failed" do
    run_import("SKU,Quantity\n#{product.sku},3\n")

    expect(response).to redirect_to(inventory_stock_issue_path(business.stock_issues.last))
    expect(business.stock_issues.last.items.sum(:quantity)).to eq(3)
    expect(business.stock_issue_import_batches.count).to eq(0)
  end

  it "posts clean rows and redirects to a draft batch for the rest" do
    run_import("SKU,Quantity\n#{product.sku},3\nUNKNOWN-SKU,2\n")

    batch = business.stock_issue_import_batches.last
    expect(response).to redirect_to(inventory_stock_issue_import_batch_path(batch))
    expect(batch).to be_draft
    expect(batch.stock_issue.items.sum(:quantity)).to eq(3)
    expect(batch.rows.pending.count).to eq(1)
    expect(batch.rows.first.failure_reason).to eq("unknown_sku")
  end

  it "never creates a second StockIssue across the whole import → resolve → complete lifecycle" do
    run_import("SKU,Quantity\n#{product.sku},3\nUNKNOWN-SKU,2\n")
    batch = business.stock_issue_import_batches.last
    row   = batch.rows.first

    expect(business.stock_issues.count).to eq(1)

    patch resolve_inventory_stock_issue_import_batch_row_path(batch, row), params: { product_id: product.id }
    patch complete_inventory_stock_issue_import_batch_path(batch)

    expect(business.stock_issues.count).to eq(1)
    issue = business.stock_issues.sole
    expect(issue).to be_posted
    expect(issue.items.sum(:quantity)).to eq(5)
  end

  describe "resolving and completing a batch" do
    it "resolves an unknown-SKU row by selecting a product, then completes the import using the SAME issue" do
      run_import("SKU,Quantity\nUNKNOWN-SKU,2\n")
      batch = business.stock_issue_import_batches.last
      row   = batch.rows.first
      draft_issue_id = batch.stock_issue_id

      patch resolve_inventory_stock_issue_import_batch_row_path(batch, row),
            params: { product_id: product.id }
      expect(row.reload).to be_resolved

      expect { patch complete_inventory_stock_issue_import_batch_path(batch) }
        .not_to change(StockIssue, :count)

      batch.reload
      expect(batch).to be_completed
      expect(batch.stock_issue_id).to eq(draft_issue_id)
      expect(batch.stock_issue).to be_posted
      expect(batch.stock_issue.items.sum(:quantity)).to eq(2)
      expect(product.stock_in(warehouse)).to eq(10 - 2)
    end

    it "skips a row and allows completion without it" do
      run_import("SKU,Quantity\n,5\n#{product.sku},3\n")
      batch = business.stock_issue_import_batches.last
      row   = batch.rows.find_by(failure_reason: "invalid_row")

      patch skip_inventory_stock_issue_import_batch_row_path(batch, row)
      expect(row.reload).to be_skipped

      patch complete_inventory_stock_issue_import_batch_path(batch)
      expect(batch.reload).to be_completed
    end

    it "edits a bad SKU inline and resolves it" do
      run_import("SKU,Quantity\nTYPO-SKU,2\n")
      batch = business.stock_issue_import_batches.last
      row   = batch.rows.first

      patch resolve_inventory_stock_issue_import_batch_row_path(batch, row), params: { sku: product.sku }
      expect(row.reload).to be_resolved
      expect(row.product).to eq(product)
    end

    it "reduces quantity to available stock for an insufficient-stock row" do
      run_import("SKU,Quantity\n#{product.sku},100\n")
      batch = business.stock_issue_import_batches.last
      row   = batch.rows.first
      expect(row.failure_reason).to eq("insufficient_stock")
      expect(row.available_hint).to eq(10)

      patch resolve_inventory_stock_issue_import_batch_row_path(batch, row), params: { quantity: 10 }
      expect(row.reload).to be_resolved
    end
  end

  describe "access control" do
    let(:viewer) do
      role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
      create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    end

    it "denies a view-only user from resolving a row" do
      run_import("SKU,Quantity\nUNKNOWN-SKU,2\n")
      batch = business.stock_issue_import_batches.last
      row   = batch.rows.first

      sign_out owner
      sign_in viewer
      patch resolve_inventory_stock_issue_import_batch_row_path(batch, row), params: { product_id: product.id }
      expect(response).to redirect_to(root_path)
      expect(row.reload).to be_pending
    end
  end
end
