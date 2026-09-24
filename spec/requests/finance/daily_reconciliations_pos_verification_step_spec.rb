require "rails_helper"

RSpec.describe "Finance::DailyReconciliations POS Transaction Verification entry point", type: :request do
  let(:business) { create(:business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  it "is not shown to a user without view_pos_import" do
    user = user_with("view_daily_reconciliation")
    sign_in user

    get finance_daily_reconciliations_path

    expect(response.body).not_to include("POS Transaction Verification")
  end

  it "renders as a plain link button — same pattern as Deposit Verification, no details/summary panel" do
    user = user_with("view_daily_reconciliation", "view_pos_import", "view_deposit_verification")
    sign_in user

    get finance_daily_reconciliations_path

    doc = Nokogiri::HTML(response.body)
    expect(doc.css("details").none? { |d| d.text.include?("POS Transaction Verification") }).to be(true)

    # Scoped to the page content — the Finance workspace nav has its own Deposit Verification link.
    pos_link = doc.css(".ws__content a").find { |a| a.text.strip == "POS Transaction Verification" }
    deposit_link = doc.css(".ws__content a").find { |a| a.text.strip == "Deposit Verification" }

    expect(pos_link).to be_present
    expect(deposit_link).to be_present
    expect(pos_link["class"]).to eq(deposit_link["class"])
    expect(pos_link["href"]).to eq(finance_pos_imports_path)
  end

  it "does not embed last-import stats on the Daily Reconciliation page itself" do
    user = user_with("view_daily_reconciliation", "view_pos_import")
    create(:pos_import, business: business, imported_by: user, file_name: "export.xlsx", status: "imported")
    sign_in user

    get finance_daily_reconciliations_path

    expect(response.body).not_to include("export.xlsx")
  end
end
