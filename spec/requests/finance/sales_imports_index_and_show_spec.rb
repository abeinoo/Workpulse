require "rails_helper"

RSpec.describe "Finance::SalesImports index and show", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:importer) { user_with("manage_sales_import", "view_sales_transactions_verification", "view_daily_reconciliation") }

  def create_sales_import(status: "imported", **attrs)
    SalesImport.create!(
      business: business, imported_by: importer, file_name: "export.csv",
      status: status, **attrs
    )
  end

  def create_sales_transaction(sales_import, **attrs)
    SalesTransaction.create!(
      business: business, sales_import: sales_import,
      transaction_date: Date.current, cashier_name: "Ahmed", branch_name: branch.name,
      payment_method_name: "Cash", amount: 100, **attrs
    )
  end

  describe "GET /finance/sales_imports" do
    it "requires manage_sales_import permission" do
      sign_in create(:user, business: business)
      get finance_sales_imports_path
      expect(response).to redirect_to(root_path)
    end

    it "lists imports with summary cards reflecting business-wide totals, unaffected by filters" do
      create_sales_import(file_name: "old.csv", total_rows: 10, matched_rows: 8, duplicate_rows: 1, failed_rows: 1)
      create_sales_import(file_name: "new.csv", total_rows: 5, matched_rows: 5, duplicate_rows: 0, failed_rows: 0)
      sign_in importer

      get finance_sales_imports_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("old.csv")
      expect(response.body).to include("new.csv")
      expect(response.body).to include(I18n.t("finance.sales_imports.index.stat_total_imports"))

      get finance_sales_imports_path(file_name: "new")
      expect(response.body).to include("new.csv")
      expect(response.body).not_to include("old.csv")
    end

    it "shows the empty state when nothing has been imported" do
      sign_in importer
      get finance_sales_imports_path
      expect(response.body).to include(I18n.t("finance.sales_imports.index.empty"))
    end

    it "links each row to the Sales Import Details page" do
      import = create_sales_import(file_name: "export.csv")
      sign_in importer

      get finance_sales_imports_path

      expect(response.body).to include(finance_sales_import_path(import))
    end
  end

  describe "GET /finance/sales_imports/:id" do
    it "requires manage_sales_import permission" do
      sign_in create(:user, business: business)
      import = create_sales_import
      get finance_sales_import_path(import)
      expect(response).to redirect_to(root_path)
    end

    it "shows import metadata, summary stats, and transactions" do
      import = create_sales_import(total_rows: 1, matched_rows: 1, duplicate_rows: 0, failed_rows: 0)
      create_sales_transaction(import, transaction_id: "TXN-1", reference_number: "REF-1")
      sign_in importer

      get finance_sales_import_path(import)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("TXN-1")
      expect(response.body).to include("REF-1")
      expect(response.body).to include(branch.name)
    end

    it "shows the empty-transactions message for an import that created no transactions" do
      import = create_sales_import
      sign_in importer

      get finance_sales_import_path(import)

      expect(response.body).to include(I18n.t("finance.sales_imports.show.empty"))
    end

    it "filters by transaction id" do
      import = create_sales_import
      create_sales_transaction(import, transaction_id: "TXN-MATCH")
      create_sales_transaction(import, transaction_id: "TXN-OTHER")
      sign_in importer

      get finance_sales_import_path(import, transaction_id: "MATCH")

      expect(response.body).to include("TXN-MATCH")
      expect(response.body).not_to include("TXN-OTHER")
    end

    it "shows the transaction's date and time of day when transaction_time is present" do
      import = create_sales_import
      # transaction_time is a time-zone-aware column (see
      # ActiveRecord::Base.time_zone_aware_types) — the real Importer always
      # writes it from inside a request under ApplicationController's
      # set_business_timezone, so mirror that here rather than writing under
      # the default UTC Time.zone.
      Time.use_zone(business.timezone_object) do
        create_sales_transaction(import, transaction_id: "TXN-TIME",
                                 transaction_date: Date.new(2026, 7, 3), transaction_time: "13:09:00")
      end
      sign_in importer

      get finance_sales_import_path(import)

      expect(response.body).to include(I18n.l(Date.new(2026, 7, 3), format: :short))
      expect(response.body).to include("13:09")
    end

    it "shows only the date when transaction_time is absent, without falling back to the import's created_at" do
      import = create_sales_import
      create_sales_transaction(import, transaction_id: "TXN-DATE-ONLY",
                               transaction_date: Date.new(2026, 7, 3), transaction_time: nil,
                               created_at: Time.zone.local(2026, 8, 1, 9, 30))
      sign_in importer

      get finance_sales_import_path(import)

      expect(response.body).to include(I18n.l(Date.new(2026, 7, 3), format: :short))
      expect(response.body).not_to include("09:30")
    end

    it "links a transaction directly to its Daily Reconciliation" do
      import = create_sales_import
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "closed",
        opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
      )
      create_sales_transaction(import, transaction_id: "TXN-DR", daily_reconciliation: dr)
      sign_in importer

      get finance_sales_import_path(import)

      expect(response.body).to include(I18n.t("finance.sales_imports.show.open_dr_action"))
      expect(response.body).to include(finance_daily_reconciliation_path(dr))
    end
  end
end
