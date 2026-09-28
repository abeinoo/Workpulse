require "rails_helper"

# CSV and Excel (.xlsx) go through the same upload -> map -> preview ->
# validate -> import pipeline. Every scenario below runs once per format.
RSpec.describe "Inventory::StockIssues import — CSV and XLSX", type: :request do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:branch)    { business.branches.create!(name: "Main Branch", active: true) }
  let!(:uyn1)      { business.products.create!(name: "أعواد خشبية كبيرة", sku: "UYN1", initial_cost_price: 30, average_cost_price: 30) }
  let!(:abc)       { business.products.create!(name: "Widget", sku: "ABC123", initial_cost_price: 10, average_cost_price: 10) }

  before do
    sign_in owner
    [ uyn1, abc ].each do |product|
      r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      r.items.build(product: product, quantity: 20, unit_cost: 10)
      Inventory::GoodsReceiptPoster.new(r).call
    end
  end

  def xlsx_type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  def file_for(format, rows)
    if format == :xlsx
      Rack::Test::UploadedFile.new(StringIO.new(xlsx_bytes(rows, types: rows.first.map { :string })), xlsx_type,
                                   original_filename: "stock.xlsx")
    else
      Rack::Test::UploadedFile.new(StringIO.new(CSV.generate { |csv| rows.each { |r| csv << r } }), "text/csv",
                                   original_filename: "stock.csv")
    end
  end

  def context_params = { warehouse_id: warehouse.id, branch_id: branch.id }
  def html = Nokogiri::HTML(response.body)
  def selected(field) = html.at_css("#mapping_#{field} option[selected]")&.text
  def payload = html.at_css("input[name=csv_payload]")["value"]
  def error_rows = html.css("#preview-errors tbody tr").map { |tr| tr.css("td").map { |td| td.text.squish }.values_at(0, -1) }
  def mapping_t(key, **) = I18n.t("inventory.imports.mapping.#{key}", **)

  def upload(format, rows, mapping: nil)
    post preview_import_inventory_stock_issues_path,
         params: context_params.merge(file: file_for(format, rows), mapping: mapping).compact
  end

  def import!(mapping, **extra)
    post run_import_inventory_stock_issues_path,
         params: context_params.merge(csv_payload: payload, mapping: mapping, **extra)
  end

  %i[csv xlsx].each do |format|
    context "#{format.upcase} upload" do
      it "reads the columns and opens the mapping step with a success message" do
        upload(format, [ %w[SKU Quantity], %w[UYN1 2] ])

        expect(response).to have_http_status(:ok)
        expect(html.at_css("#upload-success").text.squish).to eq(mapping_t("upload_success"))
        expect([ selected(:sku), selected(:quantity) ]).to eq(%w[SKU Quantity])
      end

      it "imports a valid file" do
        upload(format, [ %w[SKU Quantity], %w[UYN1 2], %w[ABC123 5] ])
        expect(html.at_css("#import-submit")["disabled"]).to be_nil
        expect(html.at_css("#import-partial")).to be_nil

        expect { import!({ sku: "0", quantity: "1" }) }.to change(StockIssue, :count).by(1)
        issue = business.stock_issues.last
        expect(response).to redirect_to(inventory_stock_issue_path(issue))
        expect(issue).to be_issued
        expect(issue.items.order(:id).map { |i| [ i.product.sku, i.quantity.to_i ] }).to eq([ [ "UYN1", 2 ], [ "ABC123", 5 ] ])
      end

      it "maps Arabic headers in a different order with extra columns, preserving row order" do
        rows = [ [ "ملاحظات", "الكمية", "المورد", "كود الصنف" ],
                 [ "عاجل", "3", "أكمي", "ABC123" ],
                 [ "", "1", "", "UYN1" ] ]
        upload(format, rows)

        expect([ selected(:sku), selected(:quantity) ]).to eq([ "كود الصنف", "الكمية" ])
        preview = html.css("#preview-rows tbody tr").map { |tr| tr.css("td").map { |td| td.text.squish }.first(2) }
        expect(preview).to eq([ %w[2 ABC123], %w[3 UYN1] ])

        import!({ sku: "3", quantity: "1" })
        expect(business.stock_issues.last.items.order(:id).map { |i| [ i.product.sku, i.quantity.to_i ] })
          .to eq([ [ "ABC123", 3 ], [ "UYN1", 1 ] ])
      end

      it "imports columns with unrelated names after manual mapping, trimming SKU whitespace" do
        upload(format, [ [ "Qty to take", "Item ref" ], [ "4", "  UYN1  " ] ])
        import!({ sku: "1", quantity: "0" })

        expect(business.stock_issues.last.items.sole).to have_attributes(product: uyn1, quantity: 4)
      end

      it "requires the SKU mapping" do
        upload(format, [ %w[Item Quantity], %w[UYN1 2] ], mapping: { sku: "", quantity: "1" })

        expect(html.at_css("#mapping-required").text.squish).to eq(mapping_t("required_summary"))
        expect(html.at_css("#import-submit")["disabled"]).to be_present
        expect { import!({ sku: "", quantity: "1" }) }.not_to change(StockIssue, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "requires the Quantity mapping" do
        upload(format, [ %w[SKU Amount], %w[UYN1 2] ], mapping: { sku: "0", quantity: "" })

        expect(html.at_css("#mapping-required")).to be_present
        expect { import!({ sku: "0", quantity: "" }) }.not_to change(StockIssue, :count)
      end

      it "rejects invalid quantities and unknown SKUs with row numbers, blocking the import" do
        rows = [ %w[SKU Quantity], %w[UYN1 2], %w[UYN1 abc], %w[ABC123 0], %w[ABC123 -1], %w[NOPE 1] ]
        upload(format, rows)

        expect(error_rows).to eq([
          [ "3", mapping_t("row_errors.invalid_quantity") ],
          [ "4", mapping_t("row_errors.non_positive_quantity") ],
          [ "5", mapping_t("row_errors.non_positive_quantity") ],
          [ "6", mapping_t("row_errors.unknown_sku") ]
        ])
        expect(html.at_css("#preview-valid-count").text).to eq("1")
        expect(html.at_css("#preview-invalid-count").text).to eq("4")
        expect(html.at_css("#import-submit")["disabled"]).to be_present
        expect(html.at_css("#import-partial")).to be_present

        expect { import!({ sku: "0", quantity: "1" }) }.not_to change(StockIssue, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(html.at_css("#import-blocked")).to be_present
      end

      it "imports valid rows and hands the rest to the fix-later screen only on explicit opt-in" do
        upload(format, [ %w[SKU Quantity], %w[UYN1 2], %w[NOPE 1] ])

        expect { import!({ sku: "0", quantity: "1" }, allow_partial: "1") }.to change(StockIssue, :count).by(1)
        batch = business.stock_issue_import_batches.last
        expect(response).to redirect_to(inventory_stock_issue_import_batch_path(batch))
        expect(batch.rows.sole).to have_attributes(sku: "NOPE", failure_reason: "unknown_sku", row_number: 3)
      end
    end
  end

  describe "file problems" do
    it "rejects unsupported formats with a clear message" do
      file = Rack::Test::UploadedFile.new(StringIO.new("x"), "application/vnd.ms-excel", original_filename: "old.xls")
      post preview_import_inventory_stock_issues_path, params: context_params.merge(file: file)

      expect(response).to redirect_to(import_inventory_stock_issues_path)
      expect(flash[:alert]).to eq(mapping_t("parse_errors.unsupported_format"))
    end

    it "handles a malformed .xlsx gracefully" do
      file = Rack::Test::UploadedFile.new(StringIO.new("not a workbook"), xlsx_type, original_filename: "bad.xlsx")
      post preview_import_inventory_stock_issues_path, params: context_params.merge(file: file)

      expect(response).to redirect_to(import_inventory_stock_issues_path)
      expect(flash[:alert]).to eq(mapping_t("parse_errors.malformed_xlsx"))
    end

    it "handles an empty .xlsx gracefully" do
      file = Rack::Test::UploadedFile.new(StringIO.new(xlsx_bytes([])), xlsx_type, original_filename: "empty.xlsx")
      post preview_import_inventory_stock_issues_path, params: context_params.merge(file: file)

      expect(flash[:alert]).to eq(mapping_t("parse_errors.empty_file"))
    end

    it "shows the Arabic error message" do
      owner.update!(preferred_locale: "ar")
      file = Rack::Test::UploadedFile.new(StringIO.new("x"), "text/plain", original_filename: "notes.txt")
      post preview_import_inventory_stock_issues_path, params: context_params.merge(file: file)

      expect(flash[:alert]).to eq("نوع الملف غير مدعوم. ارفع ملف CSV أو Excel (.xlsx).")
    end
  end

  describe "upload page and templates" do
    it "offers CSV and Excel templates and accepts both formats, without mapping fields" do
      get import_inventory_stock_issues_path

      expect(html.at_css("#download-sample-csv")["href"]).to eq(import_template_inventory_stock_issues_path)
      expect(html.at_css("#download-sample-xlsx")["href"]).to eq(import_template_inventory_stock_issues_path(kind: "xlsx"))
      expect(html.at_css("input#file")["accept"]).to include(".csv", ".xlsx")
      expect(html.at_css("label[for=file]").text.squish).to eq(mapping_t("file_label"))
      expect(html.css("[id^=mapping_]")).to be_empty
    end

    it "shows the Arabic upload labels" do
      owner.update!(preferred_locale: "ar")
      get import_inventory_stock_issues_path

      expect(response.body).to include('dir="rtl"')
      expect(html.at_css("label[for=file]").text.squish).to eq("ملف CSV أو Excel (.xlsx)")
      expect(html.at_css("#download-sample-csv").text.squish).to eq("تنزيل نموذج CSV")
      expect(html.at_css("#download-sample-xlsx").text.squish).to eq("تنزيل نموذج Excel")
      expect(html.at_css("#import-file-hint").text.squish).to include("الامتدادات المدعومة:", ".csv, .xlsx")
    end

    it "downloads an Excel template with SKU, Quantity" do
      get import_template_inventory_stock_issues_path(kind: "xlsx")

      expect(response.media_type).to eq(xlsx_type)
      expect(CSV.parse(Inventory::Imports::SpreadsheetReader.to_csv(response.body, filename: "t.xlsx")).first)
        .to eq(%w[SKU Quantity])
    end

    it "still downloads the CSV template" do
      get import_template_inventory_stock_issues_path
      expect(response.media_type).to eq("text/csv")
      expect(CSV.parse(response.body).first).to eq(%w[SKU Quantity])
    end
  end
end
