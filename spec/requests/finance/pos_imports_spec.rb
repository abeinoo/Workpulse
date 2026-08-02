require "rails_helper"

RSpec.describe "Finance::PosImports", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:importer) { user_with("view_pos_import", "manage_pos_import") }

  def headers
    [ "Transaction ID", "Order ID", "Gross Amount", "Payment Method", "Status",
      "Created At", "Paid At", "Fees", "Administrative Fees", "Product / Order Name",
      "Terminal ID", "Terminal Branch Name", "Branch ID", "Branch Name" ]
  end

  def xlsx_upload(rows)
    bytes = XlsxBuilder.build([ [ "Some Company Inc." ], [], [], [], [], [], headers ] + rows)
    file  = Tempfile.new([ "export", ".xlsx" ], binmode: true)
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  def data_row(transaction_id:, amount:, terminal_id:, fees: "0", administrative_fees: "0", status: "Success")
    [ transaction_id, "ORD-#{transaction_id}", amount, "Card", status,
      "2026-07-01 09:00:00", "2026-07-01 09:05:00", fees, administrative_fees,
      "Service", terminal_id, "Ignored", "999", "Ignored Branch" ]
  end

  before { create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-A") }

  describe "GET /finance/pos_imports (last import summary)" do
    it "shows no summary when nothing has been imported yet" do
      sign_in importer
      get finance_pos_imports_path
      expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.index.pos_last_import"))
    end

    it "shows the latest import's summary above the history table" do
      create(:pos_import, business: business, imported_by: importer, file_name: "old.xlsx", status: "imported",
             created_at: 2.days.ago, updated_at: 2.days.ago)
      latest = create(:pos_import, business: business, imported_by: importer, file_name: "newest.xlsx",
                      status: "imported", imported_rows: 7, total_amount: 500, total_fees: 20)
      sign_in importer

      get finance_pos_imports_path

      expect(response.body).to include(I18n.t("finance.daily_reconciliations.index.pos_last_import"))
      expect(response.body).to include("newest.xlsx")
      expect(latest.imported_rows).to eq(7)
    end
  end

  describe "GET /finance/pos_imports/new" do
    it "requires manage_pos_import permission" do
      sign_in create(:user, business: business)
      get new_finance_pos_import_path
      expect(response).to redirect_to(root_path)
    end

    it "renders the upload form for an authorized user" do
      sign_in importer
      get new_finance_pos_import_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("POS Import")
    end
  end

  describe "POST /finance/pos_imports" do
    it "rejects a .csv file" do
      sign_in importer
      csv = Tempfile.new([ "export", ".csv" ])
      csv.write("a,b\n1,2")
      csv.rewind
      upload = Rack::Test::UploadedFile.new(csv.path, "text/csv")

      post finance_pos_imports_path, params: { pos_import: { file: upload } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Only XLSX files are supported")
    end

    it "uploads a valid xlsx and redirects to the preview" do
      sign_in importer
      upload = xlsx_upload([ data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A") ])

      post finance_pos_imports_path, params: { pos_import: { file: upload } }

      pos_import = PosImport.last
      expect(response).to redirect_to(preview_import_finance_pos_import_path(pos_import))
    end
  end

  describe "GET /finance/pos_imports/:id/preview_import" do
    it "reports a non-Success row as ignored, not invalid, and excludes it from totals" do
      sign_in importer
      upload = xlsx_upload([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", status: "Success"),
        data_row(transaction_id: "TXN-2", amount: "40.00",  terminal_id: "TERM-A", status: "Failed")
      ])
      post finance_pos_imports_path, params: { pos_import: { file: upload } }

      get preview_import_finance_pos_import_path(PosImport.last)

      expect(response.body).to include("Ignored Transactions")
      expect(response.body).not_to include("Validation Errors")
    end

    it "shows a blocking state for unknown terminals, with the row's Excel data and an Ignore Row action" do
      sign_in importer
      upload = xlsx_upload([ data_row(transaction_id: "TXN-1", amount: "35.00", terminal_id: "GHOST") ])
      post finance_pos_imports_path, params: { pos_import: { file: upload } }

      get preview_import_finance_pos_import_path(PosImport.last)

      expect(response.body).to include("GHOST")
      expect(response.body).to include("Service")
      expect(response.body).to include("Success")
      expect(response.body).to include("Ignore Row")
      expect(response.body).to include("disabled")
    end

    it "shows the original Excel row number and values for each row-level validation error" do
      sign_in importer
      upload = xlsx_upload([
        data_row(transaction_id: "", amount: "35.00", terminal_id: "TERM-A", status: "Success")
      ])
      post finance_pos_imports_path, params: { pos_import: { file: upload } }

      get preview_import_finance_pos_import_path(PosImport.last)

      expect(response.body).to include("Row 8")
      expect(response.body).to include(I18n.t("finance.pos_imports.preview.view_row_action"))
    end

    it "shows the confirm button enabled when every terminal resolves and every row is valid" do
      sign_in importer
      upload = xlsx_upload([ data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A") ])
      post finance_pos_imports_path, params: { pos_import: { file: upload } }

      get preview_import_finance_pos_import_path(PosImport.last)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("disabled")
    end

    it "disables the confirm button while a row-level validation error remains" do
      sign_in importer
      upload = xlsx_upload([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
        data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
      ])
      post finance_pos_imports_path, params: { pos_import: { file: upload } }

      get preview_import_finance_pos_import_path(PosImport.last)

      expect(response.body).to include("Validation Errors")
      expect(response.body).to include("disabled")
      expect(response.body).to include("Ignore Row")
    end
  end

  describe "POST /finance/pos_imports/:id/ignore_row" do
    def upload_with_one_bad_row
      upload = xlsx_upload([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
        data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
      ])
      post finance_pos_imports_path, params: { pos_import: { file: upload } }
      PosImport.last
    end

    it "requires manage_pos_import permission" do
      sign_in create(:user, business: business)
      pos_import = create(:pos_import, business: business, imported_by: importer)

      post ignore_row_finance_pos_import_path(pos_import), params: { row_number: 2, reason: "x" }

      expect(response).to redirect_to(root_path)
    end

    it "ignores a row-level validation error and recalculates the preview immediately" do
      sign_in importer
      pos_import = upload_with_one_bad_row
      bad_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                    .validation.invalid_rows.first[:row_number]

      post ignore_row_finance_pos_import_path(pos_import), params: { row_number: bad_row_number, reason: "Corrupted export row" }

      expect(response).to redirect_to(preview_import_finance_pos_import_path(pos_import))
      follow_redirect!
      expect(response.body).not_to include("Validation Errors")
      expect(response.body).not_to include("disabled")
      expect(response.body).to include("Corrupted export row")
    end

    it "ignores a single Unknown Terminal ID row without requiring the terminal to be configured" do
      sign_in importer
      upload = xlsx_upload([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
        data_row(transaction_id: "TXN-2", amount: "50.00",  terminal_id: "GHOST")
      ])
      post finance_pos_imports_path, params: { pos_import: { file: upload } }
      pos_import = PosImport.last
      unknown_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                        .resolution.unknown_terminals.first[:row_number]

      post ignore_row_finance_pos_import_path(pos_import),
           params: { row_number: unknown_row_number, reason: "Bad terminal on this row only" }
      follow_redirect!

      expect(response.body).not_to include("disabled")

      post confirm_import_finance_pos_import_path(pos_import)

      expect(response).to redirect_to(finance_pos_imports_path)
      expect(pos_import.reload.status).to eq("imported")
      expect(PosTransaction.count).to eq(1)
    end

    it "persists the ignored row with reason, ignored_by, and ignored_at" do
      sign_in importer
      pos_import = upload_with_one_bad_row
      bad_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                    .validation.invalid_rows.first[:row_number]

      post ignore_row_finance_pos_import_path(pos_import), params: { row_number: bad_row_number, reason: "Corrupted export row" }

      record = pos_import.pos_import_ignored_rows.last
      expect(record.row_number).to eq(bad_row_number)
      expect(record.reason).to eq("Corrupted export row")
      expect(record.ignored_by).to eq(importer)
      expect(record.created_at).to be_present
    end

    it "rejects a blank reason" do
      sign_in importer
      pos_import = upload_with_one_bad_row
      bad_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                    .validation.invalid_rows.first[:row_number]

      post ignore_row_finance_pos_import_path(pos_import), params: { row_number: bad_row_number, reason: "" }

      expect(pos_import.pos_import_ignored_rows.count).to eq(0)
    end

    it "rejects ignoring a row that is not currently a validation error" do
      sign_in importer
      pos_import = upload_with_one_bad_row

      post ignore_row_finance_pos_import_path(pos_import), params: { row_number: 999, reason: "Nope" }

      expect(pos_import.pos_import_ignored_rows.count).to eq(0)
    end
  end

  describe "POST /finance/pos_imports/:id/confirm_import" do
    it "imports the file and shows the summary flash" do
      sign_in importer
      upload = xlsx_upload([ data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", fees: "5.00") ])
      post finance_pos_imports_path, params: { pos_import: { file: upload } }
      pos_import = PosImport.last

      post confirm_import_finance_pos_import_path(pos_import)

      expect(response).to redirect_to(finance_pos_imports_path)
      follow_redirect!
      expect(response.body).to include("Imported 1 of 1 transactions")
      expect(pos_import.reload.status).to eq("imported")
    end

    # Full-stack regression: goes through the REAL controller request cycle
    # (POST upload -> POST confirm_import), including
    # ApplicationController#set_business_timezone's around_action, exactly
    # like a real browser session — not a direct service call under a
    # manually-wrapped Time.use_zone block. Confirms the whole pipeline
    # (ExcelReader -> Mapper -> Importer -> PosTransaction) preserves the
    # real "Paid At" time-of-day end to end when the source cell is a real
    # Excel-typed datetime cell, not plain text.
    it "preserves the real Paid At time-of-day through the full upload+confirm request cycle, with a non-UTC business timezone" do
      cairo_business = create(:business, timezone: "Africa/Cairo", business_day_start_hour: 6)
      cairo_branch   = create(:branch, business: cairo_business)
      create(:pos_terminal, business: cairo_business, branch: cairo_branch, terminal_id: "TERM-CAIRO")
      role = cairo_business.permission_roles.create!(name: "Cairo-Importer", permissions: %w[view_pos_import manage_pos_import])
      cairo_importer = create(:user, business: cairo_business).tap { |u| u.update_column(:permission_role_id, role.id) }

      sign_in cairo_importer
      row = [ "TXN-REALTIME", "ORD-TXN-REALTIME", "280.00", "Card", "Success",
             "2026-07-28 02:28:12", XlsxBuilder::ExcelDateTime.new(Time.utc(2026, 7, 28, 2, 28, 13)),
             "0", "0", "Service", "TERM-CAIRO", "Ignored", "999", "Ignored Branch" ]
      bytes = XlsxBuilder.build([ [ "Some Company Inc." ], [], [], [], [], [], headers ] + [ row ])
      file  = Tempfile.new([ "export", ".xlsx" ], binmode: true)
      file.write(bytes)
      file.rewind
      upload = Rack::Test::UploadedFile.new(file.path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")

      post finance_pos_imports_path, params: { pos_import: { file: upload } }
      pos_import = PosImport.last

      post confirm_import_finance_pos_import_path(pos_import)

      txn = PosTransaction.find_by(transaction_id: "TXN-REALTIME")
      expect(txn).to be_present
      expect(txn.transaction_date.in_time_zone(cairo_business.timezone_object).strftime("%Y-%m-%d %H:%M:%S"))
        .to eq("2026-07-28 02:28:13")
    end
  end

  describe "DELETE /finance/pos_imports/:id" do
    it "deletes a pending import" do
      sign_in importer
      pos_import = create(:pos_import, business: business, imported_by: importer, status: "pending")

      expect {
        delete finance_pos_import_path(pos_import)
      }.to change(PosImport, :count).by(-1)
    end

    it "deletes a failed import" do
      sign_in importer
      pos_import = create(:pos_import, business: business, imported_by: importer, status: "failed")

      expect {
        delete finance_pos_import_path(pos_import)
      }.to change(PosImport, :count).by(-1)
    end

    it "refuses to delete a confirmed import — it's a financial document now, correct it by re-uploading instead" do
      sign_in importer
      pos_import = create(:pos_import, business: business, imported_by: importer, status: "imported")
      create(:pos_transaction, pos_import: pos_import, business: business, branch: branch)

      expect {
        delete finance_pos_import_path(pos_import)
      }.not_to change(PosImport, :count)

      expect(response).to redirect_to(root_path)
      expect(PosTransaction.where(pos_import: pos_import).count).to eq(1)
    end
  end
end
