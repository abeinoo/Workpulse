require "rails_helper"

RSpec.describe "Inventory::StockIssues#index", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:warehouse_a) { business.warehouses.create!(name: "Main") }
  let!(:warehouse_b) { business.warehouses.create!(name: "Annex") }
  let!(:branch_a)     { business.branches.create!(name: "Nasr City", active: true) }
  let!(:branch_b)     { business.branches.create!(name: "Shoubra", active: true) }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end
  let(:creator) { create(:user, business: business) }

  def receive(qty, warehouse: warehouse_a)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def post_issue(warehouse:, branch:, qty:, user: owner, issued_on: Date.current)
    issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: issued_on, created_by: user)
    issue.items.build(product: product, quantity: qty)
    approve_and_post_stock_issue(issue).issue
  end

  def expect_only(response, present:, absent: [])
    Array(present).each { |issue| expect(response.body).to include(issue.issue_number) }
    Array(absent).each  { |issue| expect(response.body).not_to include(issue.issue_number) }
  end

  before { sign_in owner }

  it "lists issued issues, newest first, and includes a real (non-import) draft" do
    receive(50)
    old_issue = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1, issued_on: 3.days.ago.to_date)
    new_issue = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1, issued_on: Date.current)
    draft = business.stock_issues.create!(warehouse: warehouse_a, branch: branch_a, issued_on: Date.current, status: :draft)

    get inventory_stock_issues_path

    expect(response.body.index(new_issue.issue_number)).to be < response.body.index(old_issue.issue_number)
    expect(response.body).to include(draft.issue_number)
  end

  it "excludes a draft still tied to an in-progress CSV import" do
    receive(50)
    import_draft = business.stock_issues.create!(warehouse: warehouse_a, branch: branch_a, issued_on: Date.current, status: :draft)
    StockIssueImportBatch.create!(business: business, warehouse: warehouse_a, branch: branch_a,
                                  stock_issue: import_draft, status: :draft)

    get inventory_stock_issues_path

    expect(response.body).not_to include(import_draft.issue_number)
  end

  it "shows the consumer branch, warehouse, item count, and total for each row" do
    receive(50)
    issue = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 4)

    get inventory_stock_issues_path

    expect(response.body).to include("Nasr City")
    expect(response.body).to include(issue.issue_number)
  end

  describe "filters" do
    before { receive(50, warehouse: warehouse_a); receive(50, warehouse: warehouse_b) }

    it "filters by warehouse" do
      matching = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1)
      other    = post_issue(warehouse: warehouse_b, branch: branch_a, qty: 1)

      get inventory_stock_issues_path, params: { warehouse_id: warehouse_a.id }

      expect_only(response, present: matching, absent: other)
    end

    it "filters by consumer branch" do
      matching = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1)
      other    = post_issue(warehouse: warehouse_a, branch: branch_b, qty: 1)

      get inventory_stock_issues_path, params: { branch_id: branch_a.id }

      expect_only(response, present: matching, absent: other)
    end

    it "filters by status (voided vs active)" do
      active = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1)
      voided = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1)
      Inventory::DocumentVoider.new(voided, user: owner, reason: "test").call

      get inventory_stock_issues_path, params: { status: "voided" }
      expect_only(response, present: voided, absent: active)

      get inventory_stock_issues_path, params: { status: "active" }
      expect_only(response, present: active, absent: voided)
    end

    it "filters by date range" do
      old_issue = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1, issued_on: 10.days.ago.to_date)
      new_issue = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1, issued_on: Date.current)

      get inventory_stock_issues_path, params: { from: 3.days.ago.to_date.to_s }

      expect_only(response, present: new_issue, absent: old_issue)
    end

    it "filters by created_by" do
      mine   = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1, user: creator)
      others = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1, user: owner)

      get inventory_stock_issues_path, params: { created_by_id: creator.id }

      expect_only(response, present: mine, absent: others)
    end
  end

  describe "search" do
    before { receive(50) }

    it "matches by issue number" do
      issue = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1)
      other = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1)

      get inventory_stock_issues_path, params: { q: issue.issue_number }

      expect_only(response, present: issue, absent: other)
    end

    it "matches by consumer branch name" do
      matching = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1)
      other    = post_issue(warehouse: warehouse_a, branch: branch_b, qty: 1)

      get inventory_stock_issues_path, params: { q: "nasr" }

      expect_only(response, present: matching, absent: other)
    end

    it "matches by warehouse name" do
      matching = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1)

      get inventory_stock_issues_path, params: { q: "main" }

      expect_only(response, present: matching)
    end

    it "matches by product SKU and name" do
      matching = post_issue(warehouse: warehouse_a, branch: branch_a, qty: 1)

      get inventory_stock_issues_path, params: { q: "sh-1" }
      expect_only(response, present: matching)

      get inventory_stock_issues_path, params: { q: "shampoo" }
      expect_only(response, present: matching)
    end
  end

  describe "header actions" do
    def header_links
      Nokogiri::HTML(response.body).css(".page-header a").to_h { |a| [ a.text.squish, a["href"] ] }
    end

    it "shows New Issue and Import Stock Issue (EN), the import pointing at the import page" do
      sign_in owner
      get inventory_stock_issues_path

      expect(header_links).to eq("Import Stock Issue" => import_inventory_stock_issues_path,
                                 "New Issue"          => new_inventory_stock_issue_path)
      expect(response.body).not_to include("Import CSV")
    end

    it "shows إذن صرف جديد and استيراد إذن صرف (AR)" do
      owner.update!(preferred_locale: "ar")
      sign_in owner
      get inventory_stock_issues_path

      expect(header_links).to eq("استيراد إذن صرف" => import_inventory_stock_issues_path,
                                 "إذن صرف جديد"    => new_inventory_stock_issue_path)
      expect(response.body).not_to include("استيراد CSV")
    end

    it "leaves the Products page's shared Import CSV label unchanged" do
      sign_in owner
      get inventory_products_path
      expect(response.body).to include(I18n.t("inventory.imports.import_csv"))
    end
  end
end
