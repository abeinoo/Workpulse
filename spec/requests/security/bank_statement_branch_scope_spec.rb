require "rails_helper"

# BUG-033 — a bank statement never names another business's branch (model
# guard, every write path), and a branch-scoped importer cannot import one for
# a branch of the business outside their scope (the form lists only assignable
# branches). Refused uploads save nothing.
RSpec.describe "Bank statement branch ownership and scope (BUG-033)", type: :request do
  let(:business)   { create(:business) }
  let!(:managed)   { create(:branch, business: business, name: "Managed") }
  let!(:unmanaged) { create(:branch, business: business, name: "Unmanaged") }
  let(:foreign)    { create(:branch, business: create(:business), name: "Foreign") }

  def importer(scope: "branch")
    role = business.permission_roles.create!(name: "Importer #{SecureRandom.hex(3)}",
                                             permissions: %w[view_deposit_verification import_bank_statement],
                                             permission_scopes: { "view_deposit_verification" => scope,
                                                                  "import_bank_statement" => scope })
    create(:user, business: business).tap do |user|
      user.update_column(:permission_role_id, role.id)
      managed.update!(branch_manager: user)
    end
  end

  def upload(branch_id)
    csv  = "Transaction Date,Reference Number,Amount,Description\n2026-07-01,DEP1001,1000.00,Cash Deposit\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "statement.csv")
    post finance_bank_statements_path, params: { bank_statement: {
      branch_id: branch_id, statement_from: "2026-07-01", statement_to: "2026-07-31", file: file
    } }
  end

  it "refuses another business's branch, saving nothing" do
    sign_in create(:user, :owner, business: business)

    expect { upload(foreign.id) }.not_to change(BankStatement, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).not_to include("Foreign")
  end

  it "refuses a branch-scoped importer a branch of the business outside their scope" do
    sign_in importer

    expect { upload(unmanaged.id) }.not_to change(BankStatement, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(CGI.escapeHTML(I18n.t("finance.bank_statements.errors.branch_outside_scope")))
  end

  it "refuses an inactive branch of the business, even to a business-wide importer, with the same explanation" do
    sign_in importer(scope: "business")
    unmanaged.update_column(:active, false)

    expect { upload(unmanaged.id) }.not_to change(BankStatement, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(CGI.escapeHTML(I18n.t("finance.bank_statements.errors.branch_outside_scope")))
  end

  it "accepts a branch the importer manages" do
    sign_in importer

    expect { upload(managed.id) }.to change(BankStatement, :count).by(1)
    expect(BankStatement.last.branch_id).to eq(managed.id)
  end

  it "lets a business-wide importer who manages no branch import for any branch, and lists them all" do
    user = importer(scope: "business")
    managed.update!(branch_manager: nil)
    sign_in user

    get new_finance_bank_statement_path
    expect(response.body).to include("Managed", "Unmanaged")

    expect { upload(unmanaged.id) }.to change(BankStatement, :count).by(1)
  end

  it "keeps accepting a statement with no branch" do
    sign_in importer

    expect { upload("") }.to change(BankStatement, :count).by(1)
    expect(BankStatement.last.branch_id).to be_nil
  end

  it "refuses another business's branch on a direct model write" do
    owner     = create(:user, :owner, business: business)
    statement = business.bank_statements.build(branch: foreign, statement_from: Date.current - 7,
                                               statement_to: Date.current, file_name: "s.csv", imported_by: owner)

    expect(statement.save).to be(false)
    expect(statement.errors.where(:branch_id, :other_business)).to be_present
  end
end
