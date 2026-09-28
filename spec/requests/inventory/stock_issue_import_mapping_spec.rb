require "rails_helper"

RSpec.describe "Inventory::StockIssues CSV import column mapping", type: :request do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:branch)    { business.branches.create!(name: "Main Branch", active: true) }
  let!(:uyn1)      { business.products.create!(name: "أعواد خشبية كبيرة", sku: "UYN1", initial_cost_price: 30, average_cost_price: 30) }
  let!(:abc)       { business.products.create!(name: "Widget", sku: "ABC123", initial_cost_price: 10, average_cost_price: 10) }

  # The real stock-order export from the other system.
  let(:real_csv) do
    <<~CSV
      Location,Supplier,Stock order ref,Status,Created,Expected,Product ID,Product name,Barcode,SKU,Qty ordered,Qty received,Product cost,Total cost
      Main,"Acme, Inc.",SO-1,Received,2026-09-01,2026-09-02,901,أعواد خشبية كبيرة,6281000000011,UYN1,2,2,35.00,70.00
      Main,"Acme, Inc.",SO-1,Received,2026-09-01,2026-09-02,902,Widget,6281000000028,ABC123,5,4,10.00,50.00
    CSV
  end

  before do
    sign_in owner
    [ uyn1, abc ].each do |product|
      r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      r.items.build(product: product, quantity: 20, unit_cost: 10)
      Inventory::GoodsReceiptPoster.new(r).call
    end
  end

  def upload(csv, name: "export.csv") = Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: name)
  def context_params = { warehouse_id: warehouse.id, branch_id: branch.id }
  def page = Nokogiri::HTML(response.body)
  def selected_header(field) = page.at_css("#mapping_#{field} option[selected]")&.text
  def payload_from_page = page.at_css("input[name=csv_payload]")["value"]
  def import_button = page.at_css("#import-submit")

  def preview(csv, mapping: nil)
    post preview_import_inventory_stock_issues_path,
         params: context_params.merge(file: upload(csv), mapping: mapping).compact
  end

  def import_with(payload, mapping)
    post run_import_inventory_stock_issues_path,
         params: context_params.merge(csv_payload: payload, mapping: mapping)
  end

  describe "upload -> match columns" do
    it "does not reject a file with non-standard headers; opens the mapping step with suggestions" do
      preview(real_csv)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("inventory.imports.invalid_headers"))
      expect(selected_header(:sku)).to eq("SKU")
      expect(selected_header(:quantity)).to eq("Qty ordered")
      # Every CSV column plus "Ignore" is offered.
      expect(page.css("#mapping_quantity option").map(&:text))
        .to eq([ I18n.t("inventory.imports.mapping.ignore_column") ] + real_csv.lines.first.chomp.split(","))
      expect(import_button["disabled"]).to be_nil
    end

    it "marks required fields with * and shows the chosen CSV column next to the mapping" do
      preview(real_csv)
      labels = page.css("label[for^=mapping_]").map { |l| l.text.squish }
      expect(labels).to all(include("*"))
      expect(page.at_css("[data-field=quantity][data-import-mapping-target=source]").text).to include("Qty ordered")
    end

    it "blocks import until SKU and Quantity are both mapped" do
      preview("Item,Amount to take\nUYN1,2\n")

      expect(selected_header(:sku)).to be_nil
      expect(import_button["disabled"]).to be_present
      expect(page.css("#preview-rows")).to be_empty
      expect(response.body).to include(I18n.t("inventory.imports.mapping.errors.required_missing"))
    end

    it "refuses to import without a valid mapping, even if the button is bypassed" do
      preview("Item,Amount to take\nUYN1,2\n")
      expect {
        import_with(payload_from_page, { sku: "0", quantity: "" })
      }.not_to change(StockIssue, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "refuses the same column for both fields" do
      preview("Item,Amount to take\nUYN1,2\n", mapping: { sku: "0", quantity: "0" })
      expect(response.body).to include(I18n.t("inventory.imports.mapping.errors.duplicate_column"))
      expect(import_button["disabled"]).to be_present
    end

    it "redirects back with a clear message for a non-UTF-8 file" do
      preview("SKU,Quantity\n\xFF\xFE,1\n".b)
      expect(response).to redirect_to(import_inventory_stock_issues_path)
      expect(flash[:alert]).to eq(I18n.t("inventory.imports.mapping.parse_errors.invalid_encoding"))
    end
  end

  describe "preview" do
    it "lists valid and invalid rows with row numbers and reasons" do
      csv = "Code,Qty ordered,Total cost\nUYN1,2,70\n,5,1\nABC123,abc,1\nABC123,0,1\nABC123,-1,1\nNOPE,1,1\n"
      preview(csv)

      expect(page.at_css("#preview-valid-count").text).to eq("1")
      expect(page.at_css("#preview-invalid-count").text).to eq("5")
      errors = page.css("#preview-errors tbody tr").map { |tr| tr.css("td").map { |td| td.text.squish } }
      expect(errors.map { |cells| [ cells.first, cells.last ] }).to eq([
        [ "3", "Missing SKU" ],
        [ "4", "Invalid quantity" ],
        [ "5", "Quantity must be greater than zero" ],
        [ "6", "Quantity must be greater than zero" ],
        [ "7", "SKU does not exist" ]
      ])
      preview_row = page.at_css("#preview-rows tbody tr").css("td").map { |td| td.text.squish }
      expect(preview_row).to eq([ "2", "UYN1", "أعواد خشبية كبيرة", "2", "Ready" ])
    end

    it "does not create anything" do
      expect { preview(real_csv) }.not_to change { [ StockIssue.count, InventoryMovement.count ] }
    end
  end

  describe "import" do
    it "imports the real export via the SKU / Qty ordered mapping" do
      preview(real_csv)
      import_with(payload_from_page, { sku: "9", quantity: "10" })

      issue = business.stock_issues.last
      expect(response).to redirect_to(inventory_stock_issue_path(issue))
      expect(issue).to be_issued
      expect(issue.items.map { |i| [ i.product.sku, i.quantity.to_i ] }).to contain_exactly([ "UYN1", 2 ], [ "ABC123", 5 ])
    end

    it "uses the mapped column, not a same-named one — e.g. Qty received instead of Qty ordered" do
      preview(real_csv)
      import_with(payload_from_page, { sku: "9", quantity: "11" })
      expect(business.stock_issues.last.items.map { |i| i.quantity.to_i }).to contain_exactly(2, 4)
    end

    it "imports a file with unrelated column names after manual mapping" do
      preview("Item,Amount to take,Notes\nUYN1,3,x\n")
      import_with(payload_from_page, { sku: "0", quantity: "1" })
      expect(business.stock_issues.last.items.sole).to have_attributes(product: uyn1, quantity: 3)
    end

    it "imports Arabic headers" do
      preview("رمز المنتج,الكمية\nUYN1,4\n")
      expect(selected_header(:sku)).to eq("رمز المنتج")
      import_with(payload_from_page, { sku: "0", quantity: "1" })
      expect(business.stock_issues.last.items.sole.quantity).to eq(4)
    end

    it "still imports the standard template posted straight to run_import (auto-matched)" do
      post run_import_inventory_stock_issues_path,
           params: context_params.merge(file: upload("SKU,Quantity\nUYN1,3\n"))
      expect(response).to redirect_to(inventory_stock_issue_path(business.stock_issues.last))
    end

    it "sends a direct upload with unmatched headers to the mapping step instead of rejecting it" do
      expect {
        post run_import_inventory_stock_issues_path, params: context_params.merge(file: upload("Item,Amount\nUYN1,3\n"))
      }.not_to change(StockIssue, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(page.at_css("#mapping_sku")).to be_present
    end

    it "keeps the existing resolution workflow: bad rows go to a draft batch on the same single issue" do
      preview("SKU,Qty\nUYN1,2\nNOPE,1\n")
      expect {
        post run_import_inventory_stock_issues_path,
             params: context_params.merge(csv_payload: payload_from_page, mapping: { sku: "0", quantity: "1" }, allow_partial: "1")
      }.to change(StockIssue, :count).by(1)

      batch = business.stock_issue_import_batches.last
      expect(response).to redirect_to(inventory_stock_issue_import_batch_path(batch))
      expect(batch.stock_issue).to be_draft
      expect(batch.rows.sole).to have_attributes(sku: "NOPE", failure_reason: "unknown_sku", row_number: 3)
    end
  end

  describe "RTL / LTR" do
    %w[en ar].each do |locale|
      it "renders the mapping + preview page in #{locale}" do
        owner.update!(preferred_locale: locale)
        preview(real_csv)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(dir="#{locale == 'ar' ? 'rtl' : 'ltr'}"))
        expect(response.body).to include(I18n.t("inventory.imports.mapping.title", locale: locale))
        expect(response.body).to include("أعواد خشبية كبيرة")
      end
    end
  end

  describe "permissions" do
    let(:viewer) do
      role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
      create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    end

    it "denies a view-only user at every step" do
      sign_out owner
      sign_in viewer

      preview(real_csv)
      expect(response).to redirect_to(root_path)

      expect {
        post run_import_inventory_stock_issues_path, params: context_params.merge(file: upload("SKU,Quantity\nUYN1,1\n"))
      }.not_to change(StockIssue, :count)
      expect(response).to redirect_to(root_path)
    end

    it "does not allow importing into a warehouse the user cannot access" do
      other = business.warehouses.create!(name: "Other")
      allow_any_instance_of(User).to receive(:inventory_warehouse_ids).and_return([ warehouse.id ])

      post preview_import_inventory_stock_issues_path,
           params: { warehouse_id: other.id, branch_id: branch.id, file: upload(real_csv) }
      expect(response).to redirect_to(import_inventory_stock_issues_path)
    end
  end
end
