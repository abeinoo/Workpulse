require "rails_helper"

RSpec.describe "Finance::BankStatements POS-import-first workflow warning", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

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

  def upload_csv
    csv = <<~CSV
      Transaction Date,Reference Number,Amount,Description
      2026-07-01,DEP1001,1000.00,Cash Deposit
    CSV
    Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "statement.csv")
  end

  it "warns when no POS transactions exist yet for the statement's branch and date range" do
    post finance_bank_statements_path, params: {
      bank_statement: {
        branch_id:      branch.id,
        statement_from: "2026-07-01",
        statement_to:   "2026-07-31",
        file:           upload_csv
      }
    }

    statement = BankStatement.last
    expect(response).to redirect_to(edit_column_mapping_finance_bank_statement_path(statement))
    follow_redirect!
    expect(response.body).to include(I18n.t("finance.bank_statements.pos_not_imported_warning"))
  end

  it "does not warn once a POS transaction exists in that branch and date range" do
    create(:pos_transaction, business: business, branch: branch, transaction_date: Time.zone.parse("2026-07-15 10:00"))

    post finance_bank_statements_path, params: {
      bank_statement: {
        branch_id:      branch.id,
        statement_from: "2026-07-01",
        statement_to:   "2026-07-31",
        file:           upload_csv
      }
    }

    statement = BankStatement.last
    follow_redirect!
    expect(response.body).not_to include(I18n.t("finance.bank_statements.pos_not_imported_warning"))
  end

  it "does not warn about missing POS transactions from a different branch" do
    other_branch = create(:branch, business: business)
    create(:pos_transaction, business: business, branch: other_branch, transaction_date: Time.zone.parse("2026-07-15 10:00"))

    post finance_bank_statements_path, params: {
      bank_statement: {
        branch_id:      branch.id,
        statement_from: "2026-07-01",
        statement_to:   "2026-07-31",
        file:           upload_csv
      }
    }

    follow_redirect!
    expect(response.body).to include(I18n.t("finance.bank_statements.pos_not_imported_warning"))
  end
end
