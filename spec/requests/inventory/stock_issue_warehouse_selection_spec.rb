require "rails_helper"

# Standard Stock Issue screens — warehouse-based authorization: the New / Edit
# form and the import upload offer ONE warehouse field (the only authorized
# warehouse shown and used automatically, or a selector of exactly the
# authorized active ones), no consuming-branch field, and every submitted
# warehouse id is re-checked on the server.
RSpec.describe "Stock Issue warehouse selection", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:nasr)     { business.branches.create!(name: "Nasr City", active: true) }
  let!(:nasr_wh) { branch_warehouse_for(nasr, name: "Nasr WH") }
  let!(:central) { business.warehouses.create!(name: "Central", kind: "central") }
  let!(:annex)   { business.warehouses.create!(name: "Annex", kind: "central") }
  let!(:closed)  { business.warehouses.create!(name: "Closed", kind: "central").tap { |w| w.update_column(:status, "inactive") } }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let(:user)     { stock_issue_user(business, :create_stock_issues) }

  def html = Nokogiri::HTML(response.body)
  # The warehouse options (the blank "Select warehouse" prompt excluded).
  def warehouse_select = html.css("select[name='stock_issue[warehouse_id]'] option").select { |o| o["value"].present? }.map(&:text)

  def create_issue(warehouse_id)
    post inventory_stock_issues_path, params: { stock_issue: {
      warehouse_id: warehouse_id, branch_id: nasr.id, issued_on: Date.current,
      items_attributes: { "0" => { product_id: product.id, quantity: 1 } }
    } }
  end

  before { sign_in user }

  describe "New Stock Issue" do
    it "uses the only authorized warehouse automatically — no selector, no branch field" do
      restrict_to_warehouses!(user, central)
      get new_inventory_stock_issue_path
      expect(html.css("select[name='stock_issue[warehouse_id]']")).to be_empty
      expect(html.at_css("[data-testid='stock-issue-warehouse-name']").text).to eq("Central")
      expect(html.at_css("input[type='hidden'][name='stock_issue[warehouse_id]']")["value"]).to eq(central.id.to_s)
      expect(html.css("[name='stock_issue[branch_id]']")).to be_empty
    end

    it "offers only the authorized active warehouses when there are several" do
      restrict_to_warehouses!(user, central, annex, closed)
      get new_inventory_stock_issue_path
      expect(warehouse_select).to eq(%w[Annex Central])
    end

    it "explains when no active warehouse is accessible" do
      restrict_to_warehouses!(user, closed)
      get new_inventory_stock_issue_path
      expect(html.at_css("[data-testid='issue-warehouse-notice']").text)
        .to eq(I18n.t("inventory.issue_warehouse.errors.none_accessible"))
    end

    it "creates the draft in the selected warehouse, ignoring any submitted branch" do
      restrict_to_warehouses!(user, central, annex)
      expect { create_issue(annex.id) }.to change(StockIssue, :count).by(1)
      expect(StockIssue.last).to have_attributes(warehouse_id: annex.id, branch_id: nil, warehouse_source: "selected")
    end

    it "rejects a tampered, unauthorized, inactive or foreign warehouse id" do
      restrict_to_warehouses!(user, central, closed)
      foreign = create(:business).warehouses.create!(name: "Foreign")
      [ annex.id, nasr_wh.id, closed.id, foreign.id, "abc" ].each do |id|
        expect { create_issue(id) }.not_to change(StockIssue, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  describe "Edit" do
    let(:issue) do
      restrict_to_warehouses!(user, central, annex)
      i = business.stock_issues.build(warehouse: central, issued_on: Date.current, created_by: user)
      i.items.build(product: product, quantity: 1)
      Inventory::StockIssueDraftService.new(i, actor: user).call
      i
    end

    it "offers the authorized warehouses, with the current one selected" do
      get edit_inventory_stock_issue_path(issue)
      expect(warehouse_select).to eq(%w[Annex Central])
      expect(html.at_css("select[name='stock_issue[warehouse_id]'] option[selected]").text).to eq("Central")
    end

    it "refuses moving the issue to an unauthorized warehouse" do
      patch inventory_stock_issue_path(issue), params: { lock_token: issue.lock_token, stock_issue: { warehouse_id: nasr_wh.id } }
      expect(issue.reload.warehouse_id).to eq(central.id)
    end
  end

  describe "Import" do
    it "offers the authorized warehouses and no branch field" do
      restrict_to_warehouses!(user, central, annex)
      get import_inventory_stock_issues_path
      expect(html.css("select[name='warehouse_id'] option").select { |o| o["value"].present? }.map(&:text)).to eq(%w[Annex Central])
      expect(html.css("[name='branch_id']")).to be_empty
    end

    it "refuses an unauthorized warehouse before reading the file" do
      restrict_to_warehouses!(user, central)
      file = Rack::Test::UploadedFile.new(StringIO.new("SKU,Quantity\nSH-1,1\n"), "text/csv", original_filename: "i.csv")
      post preview_import_inventory_stock_issues_path, params: { file: file, warehouse_id: annex.id }
      expect(response).to redirect_to(import_inventory_stock_issues_path)
      expect(flash[:alert]).to eq(I18n.t("inventory.issue_warehouse.errors.not_allowed"))
    end
  end

  describe "visibility" do
    it "lists only issues of warehouses the user may use (no branch filter)" do
      mine  = business.stock_issues.create!(warehouse: central, issued_on: Date.current, status: :draft)
      other = business.stock_issues.create!(warehouse: annex, branch: nasr, issued_on: Date.current, status: :draft)
      restrict_to_warehouses!(user, central)

      expect(Pundit.policy_scope!(user.reload, StockIssue)).to contain_exactly(mine)
      get inventory_stock_issue_path(other)
      expect(response).to have_http_status(:not_found).or redirect_to(root_path)
    end
  end
end
