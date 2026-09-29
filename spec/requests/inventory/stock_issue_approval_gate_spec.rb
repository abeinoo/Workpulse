require "rails_helper"

# Server-side enforcement of the stock-issue approval gate at the HTTP layer:
# hiding a button is not the control — every endpoint must refuse to deduct
# stock for an issue that hasn't been approved.
RSpec.describe "Inventory::StockIssues approval gate", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  let(:creator_role)   { create(:permission_role, business: business, permissions: %w[view_inventory manage_stock_issues]) }
  let(:creator)        { create(:user, business: business, permission_role: creator_role) }
  let(:approver_role)  { create(:permission_role, business: business, permissions: %w[view_inventory approve_stock_issues]) }
  let(:approver)       { create(:user, business: business, permission_role: approver_role) }
  let(:confirmer_role) { create(:permission_role, business: business, permissions: %w[view_inventory confirm_stock_issues]) }
  let(:confirmer)      { create(:user, business: business, permission_role: confirmer_role) }

  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def html = Nokogiri::HTML(response.body)

  ISSUE_NOTE = "صرف مستلزمات للفرع لتغطية احتياج الأسبوع".freeze

  def import_csv!(csv, notes: nil)
    file = Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "issue.csv")
    post run_import_inventory_stock_issues_path,
         params: { file: file, warehouse_id: warehouse.id, branch_id: branch.id, notes: notes }.compact
  end

  def imported_issue
    sign_in creator
    import_csv!("SKU,Quantity\n#{product.sku},4\n", notes: ISSUE_NOTE)
    business.stock_issues.last
  end

  describe "import" do
    it "creates a pending-approval issue and deducts nothing" do
      expect { imported_issue }.to change(StockIssue, :count).by(1).and not_change(InventoryMovement, :count)

      issue = business.stock_issues.last
      expect(issue).to be_pending_approval
      expect(issue.notes).to eq(ISSUE_NOTE)
      expect(product.reload.current_stock).to eq(10)
    end

    it "explains on the upload page that imports require approval before stock is deducted" do
      sign_in creator
      get import_inventory_stock_issues_path

      expect(html.at_css("#import-approval-notice").text.squish)
        .to eq(I18n.t("inventory.imports.stock_issues.approval_required"))
      expect(html.css("table code").map(&:text)).to eq(%w[SKU Quantity])
      # The document-level note is a form field, separate from the file's columns.
      expect(html.at_css("label[for=notes]").text.squish).to eq(I18n.t("inventory.imports.stock_issues.issue_notes_label"))
      expect(html.at_css("textarea#notes[name=notes]")).to be_present
      expect(html.at_css("textarea#notes")["required"]).to be_nil
    end
  end

  describe "posting before approval is refused server-side" do
    it "rejects a direct Confirm call on a pending issue, even from a user holding the confirm permission" do
      issue = imported_issue
      sign_in confirmer

      expect { post confirm_inventory_stock_issue_path(issue) }.not_to change(InventoryMovement, :count)
      expect(response).to redirect_to(root_path)
      expect(issue.reload).to be_pending_approval
      expect(product.reload.current_stock).to eq(10)
    end

    it "rejects a direct Confirm call even from a super admin" do
      issue = imported_issue
      sign_in owner

      expect { post confirm_inventory_stock_issue_path(issue) }.not_to change(InventoryMovement, :count)
      expect(issue.reload).to be_pending_approval
    end

    it "rejects a direct JSON Confirm call" do
      issue = imported_issue
      sign_in confirmer

      expect { post confirm_inventory_stock_issue_path(issue), as: :json }.not_to change(InventoryMovement, :count)
      expect(issue.reload).to be_pending_approval
    end

    it "rejects Confirm on a draft (manually created, never submitted)" do
      sign_in creator
      post inventory_stock_issues_path, params: {
        stock_issue: { warehouse_id: warehouse.id, branch_id: branch.id, issued_on: Date.current,
                       items_attributes: { "0" => { product_id: product.id, quantity: 2 } } }
      }
      issue = business.stock_issues.last
      expect(issue).to be_draft

      sign_in owner
      expect { post confirm_inventory_stock_issue_path(issue) }.not_to change(InventoryMovement, :count)
      expect(issue.reload).to be_draft
    end

    it "exposes no JSON API route that creates or posts a stock issue" do
      api_paths = Rails.application.routes.routes.map { |r| r.path.spec.to_s }.grep(%r{\A/api/})
      expect(api_paths.grep(/stock_issue/)).to be_empty
    end
  end

  describe "tampered requests cannot set the status" do
    it "ignores a status param on create" do
      sign_in creator
      post inventory_stock_issues_path, params: {
        stock_issue: { warehouse_id: warehouse.id, branch_id: branch.id, issued_on: Date.current, status: "issued",
                       items_attributes: { "0" => { product_id: product.id, quantity: 2 } } }
      }

      expect(business.stock_issues.last).to be_draft
      expect(InventoryMovement.where(source_type: "StockIssue")).to be_empty
    end

    it "ignores a status param on update" do
      sign_in creator
      post inventory_stock_issues_path, params: {
        stock_issue: { warehouse_id: warehouse.id, branch_id: branch.id, issued_on: Date.current,
                       items_attributes: { "0" => { product_id: product.id, quantity: 2 } } }
      }
      issue = business.stock_issues.last

      patch inventory_stock_issue_path(issue), params: { stock_issue: { status: "approved" } }
      expect(issue.reload).to be_draft
    end
  end

  describe "approved issue proceeds through the existing workflow" do
    it "import -> approve -> confirm deducts stock exactly once, at confirm" do
      issue = imported_issue

      sign_in approver
      post approve_inventory_stock_issue_path(issue)
      expect(issue.reload).to be_approved
      expect(product.reload.current_stock).to eq(10)

      sign_in confirmer
      post confirm_inventory_stock_issue_path(issue)
      expect(issue.reload).to be_issued
      expect(product.reload.current_stock).to eq(6)

      post confirm_inventory_stock_issue_path(issue) # repeat is refused by the policy
      expect(product.reload.current_stock).to eq(6)
    end

    it "keeps permissions enforced: an approver cannot confirm, a confirmer cannot approve" do
      issue = imported_issue

      sign_in confirmer
      post approve_inventory_stock_issue_path(issue)
      expect(issue.reload).to be_pending_approval

      sign_in approver
      post approve_inventory_stock_issue_path(issue)
      post confirm_inventory_stock_issue_path(issue)
      expect(issue.reload).to be_approved
      expect(product.reload.current_stock).to eq(10)
    end
  end

  describe "status display" do
    it "shows a pending import as في انتظار الاعتماد with a no-deduction notice, never as issued" do
      issue = imported_issue
      creator.update!(preferred_locale: "ar")

      get inventory_stock_issue_path(issue)

      badge = html.at_css(".page-title .badge").text.squish
      expect(badge).to eq("في انتظار الاعتماد")
      expect(response.body).not_to include(I18n.t("inventory.stock_issues.statuses.issued", locale: :ar))
      expect(html.at_css("#stock-not-deducted-notice").text.squish)
        .to eq(I18n.t("inventory.stock_issues.stock_not_deducted_pending_approval", locale: :ar))
      expect(html.at_css(".detail-list").text).to include(ISSUE_NOTE)
    end

    it "lists a pending import with its pending status, never as issued" do
      issue = imported_issue

      get inventory_stock_issues_path

      row = html.css("tr").find { |tr| tr.text.include?(issue.issue_number) }
      expect(row.text).to include(I18n.t("inventory.stock_issues.statuses.pending_approval"))
      expect(row.text).not_to include(I18n.t("inventory.stock_issues.statuses.issued"))
    end

    it "drops the no-deduction notice once the issue is confirmed" do
      issue = imported_issue
      Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!
      Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: confirmer).call

      get inventory_stock_issue_path(issue)
      expect(html.at_css("#stock-not-deducted-notice")).to be_nil
    end
  end
end
