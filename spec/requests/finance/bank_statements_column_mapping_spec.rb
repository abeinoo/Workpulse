require "rails_helper"

RSpec.describe "Finance::BankStatements multilingual column mapping", type: :request do
  let(:business) { create(:business) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:importer) { user_with("import_bank_statement", "view_deposit_verification") }

  before { sign_in importer }

  def upload(fixture_name, content_type: "text/csv")
    fixture_file_upload(Rails.root.join("spec/fixtures/files/#{fixture_name}"), content_type)
  end

  describe "uploading a CSV with Arabic headers and content" do
    it "detects the Arabic headers verbatim on the column mapping step" do
      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           upload("bank_statement_arabic.csv")
        }
      }

      statement = BankStatement.last
      expect(response).to redirect_to(edit_column_mapping_finance_bank_statement_path(statement))

      get edit_column_mapping_finance_bank_statement_path(statement)

      expect(response.body).to include("تاريخ المعاملة")
      expect(response.body).to include("المبلغ")
      expect(response.body).to include("رقم المرجع")
      expect(response.body).to include("الوصف")
    end

    it "pre-selects the auto-detected mapping, each header assigned to exactly one field" do
      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           upload("bank_statement_arabic.csv")
        }
      }
      statement = BankStatement.last

      get edit_column_mapping_finance_bank_statement_path(statement)
      doc = Nokogiri::HTML(response.body)

      selected = %w[transaction_date amount reference_number description].index_with do |field|
        doc.at_css("select[name='column_mapping[#{field}]'] option[selected]")&.attr("value")
      end

      expect(selected).to eq(
        "transaction_date" => "تاريخ المعاملة",
        "amount"           => "المبلغ",
        "reference_number" => "رقم المرجع",
        "description"      => "الوصف"
      )
      expect(selected.values.uniq.size).to eq(selected.values.size)
    end

    it "imports rows and preserves Arabic content through matching and mapping" do
      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           upload("bank_statement_arabic.csv")
        }
      }
      statement = BankStatement.last

      patch update_column_mapping_finance_bank_statement_path(statement), params: {
        column_mapping: {
          "transaction_date" => "تاريخ المعاملة",
          "amount"           => "المبلغ",
          "reference_number" => "رقم المرجع",
          "description"      => "الوصف"
        }
      }
      expect(response).to redirect_to(preview_import_finance_bank_statement_path(statement))

      post confirm_import_finance_bank_statement_path(statement)
      statement.reload

      expect(statement.status).to eq("completed")
      expect(statement.total_rows).to eq(2)

      txn = statement.bank_statement_transactions.order(:transaction_date).first
      expect(txn.description).to eq("إيداع نقدي")
      expect(txn.reference_number).to eq("DEP1001")
      expect(txn.amount).to eq(1000.00)
    end
  end

  describe "uploading a CSV with English headers" do
    it "still imports correctly (no regression)" do
      csv = <<~CSV
        Transaction Date,Amount,Reference Number,Description
        2026-07-01,1000.00,DEP1001,Cash Deposit
      CSV
      io = StringIO.new(csv)
      file = Rack::Test::UploadedFile.new(io, "text/csv", original_filename: "english.csv")

      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           file
        }
      }
      statement = BankStatement.last
      expect(response).to redirect_to(edit_column_mapping_finance_bank_statement_path(statement))

      patch update_column_mapping_finance_bank_statement_path(statement), params: {
        column_mapping: {
          "transaction_date" => "Transaction Date",
          "amount"           => "Amount",
          "reference_number" => "Reference Number",
          "description"      => "Description"
        }
      }

      post confirm_import_finance_bank_statement_path(statement)
      statement.reload

      expect(statement.status).to eq("completed")
      txn = statement.bank_statement_transactions.first
      expect(txn.description).to eq("Cash Deposit")
    end
  end

  describe "uploading an Excel (.xlsx) file with English headers" do
    it "detects headers and imports rows identically to CSV" do
      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           upload("bank_statement_english.xlsx",
                                  content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        }
      }
      statement = BankStatement.last
      expect(response).to redirect_to(edit_column_mapping_finance_bank_statement_path(statement))

      get edit_column_mapping_finance_bank_statement_path(statement)
      expect(response.body).to include("Transaction Date")
      expect(response.body).to include("Reference Number")

      patch update_column_mapping_finance_bank_statement_path(statement), params: {
        column_mapping: {
          "transaction_date" => "Transaction Date",
          "amount"           => "Amount",
          "reference_number" => "Reference Number",
          "description"      => "Description"
        }
      }
      expect(response).to redirect_to(preview_import_finance_bank_statement_path(statement))

      post confirm_import_finance_bank_statement_path(statement)
      statement.reload

      expect(statement.status).to eq("completed")
      expect(statement.total_rows).to eq(2)

      txn = statement.bank_statement_transactions.order(:transaction_date).first
      expect(txn.reference_number).to eq("DEP1001")
      expect(txn.amount).to eq(1000)
      expect(txn.transaction_date.to_s).to eq("2026-07-01")
    end
  end

  describe "uploading an Excel (.xlsx) file with Arabic headers" do
    it "detects Arabic headers and imports rows correctly" do
      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           upload("bank_statement_arabic.xlsx",
                                  content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        }
      }
      statement = BankStatement.last

      get edit_column_mapping_finance_bank_statement_path(statement)
      expect(response.body).to include("تاريخ المعاملة")
      expect(response.body).to include("الوصف")

      patch update_column_mapping_finance_bank_statement_path(statement), params: {
        column_mapping: {
          "transaction_date" => "تاريخ المعاملة",
          "amount"           => "المبلغ",
          "reference_number" => "رقم المرجع",
          "description"      => "الوصف"
        }
      }
      post confirm_import_finance_bank_statement_path(statement)
      statement.reload

      expect(statement.status).to eq("completed")
      txn = statement.bank_statement_transactions.order(:transaction_date).first
      expect(txn.description).to eq("إيداع نقدي")
    end
  end

  describe "uploading a legacy Excel (.xls) file" do
    it "reads headers and imports rows via the roo-xls adapter" do
      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           upload("bank_statement_english.xls", content_type: "application/vnd.ms-excel")
        }
      }
      statement = BankStatement.last
      expect(response).to redirect_to(edit_column_mapping_finance_bank_statement_path(statement))

      patch update_column_mapping_finance_bank_statement_path(statement), params: {
        column_mapping: {
          "transaction_date" => "Transaction Date",
          "amount"           => "Amount",
          "reference_number" => "Reference Number",
          "description"      => "Description"
        }
      }
      post confirm_import_finance_bank_statement_path(statement)
      statement.reload

      expect(statement.status).to eq("completed")
      expect(statement.bank_statement_transactions.first.reference_number).to eq("DEP1001")
    end
  end

  describe "uploading an unsupported file type" do
    it "rejects the upload with a clear validation message" do
      io   = StringIO.new("%PDF-1.4 not really a statement")
      file = Rack::Test::UploadedFile.new(io, "application/pdf", original_filename: "statement.pdf")

      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           file
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("finance.bank_statements.errors.unsupported_file_type"))
      expect(BankStatement.count).to eq(0)
    end
  end

  describe "uploading a corrupt Excel file" do
    it "rejects the upload with a malformed-file message instead of raising" do
      io   = StringIO.new("this is not a real xlsx file")
      file = Rack::Test::UploadedFile.new(io, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                                           original_filename: "broken.xlsx")

      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           file
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("finance.bank_statements.errors.file_malformed"))
      expect(BankStatement.count).to eq(0)
    end
  end

  describe "an Arabic-locale user importing rows with an Arabic-month date" do
    let(:importer) do
      user_with("import_bank_statement", "view_deposit_verification").tap do |u|
        u.update_column(:preferred_locale, "ar")
      end
    end

    it "parses Arabic month-name dates and shows only localized Arabic error text on the preview page, never raw English" do
      csv = <<~CSV
        Transaction Date,Amount,Reference Number
        17 يوليو 2026,1000.00,DEP1001
        not-a-real-date,500.00,DEP1002
      CSV
      io   = StringIO.new(csv)
      file = Rack::Test::UploadedFile.new(io, "text/csv", original_filename: "arabic_dates.csv")

      post finance_bank_statements_path, params: {
        bank_statement: {
          statement_from: "2026-07-01",
          statement_to:   "2026-07-31",
          file:           file
        }
      }
      statement = BankStatement.last

      patch update_column_mapping_finance_bank_statement_path(statement), params: {
        column_mapping: {
          "transaction_date" => "Transaction Date",
          "amount"           => "Amount",
          "reference_number" => "Reference Number"
        }
      }
      expect(response).to redirect_to(preview_import_finance_bank_statement_path(statement))

      get preview_import_finance_bank_statement_path(statement)

      # The valid row (Arabic month name) parsed correctly.
      expect(response.body).to include("DEP1001")

      # The invalid row's error is shown in Arabic, matching the user's locale...
      expect(response.body).to include(
        I18n.t("finance.bank_statements.row_errors.transaction_date_invalid", value: "not-a-real-date", locale: :ar)
      )
      # ...and the old raw English exception string never appears anywhere on the page.
      expect(response.body).not_to include("is not a recognised date format")
      expect(response.body).not_to include("IS NOT A RECOGNISED DATE FORMAT")
    end
  end
end
