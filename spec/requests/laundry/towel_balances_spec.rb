require "rails_helper"

RSpec.describe "Laundry towel balances — simplified operational view", type: :request do
  let(:business) { create(:business) }
  let(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # Laundry::BaseController#assignable_branches (mirrors Finance's) is purely
  # management-based (branch_manager_id/area_manager_id) for non-owners — it
  # doesn't consult permission_scopes. Making the test user branch_manager of
  # both branches is what makes them show up on the page at all.
  def manage_both_branches!(user)
    sales_branch.update!(branch_manager_id: user.id)
    laundry_branch.update!(branch_manager_id: user.id)
  end

  let(:owner) { create(:user, :owner, business: business) }
  let(:plain_viewer) { user_with("view_towel_balances").tap { |u| manage_both_branches!(u) } }
  let(:auditor) { user_with("view_towel_balances", "adjust_towel_balances").tap { |u| manage_both_branches!(u) } }

  def fund(branch, status, quantity, actor: owner)
    Laundry::TowelAdjuster.new(actor: actor).call(
      towel_type: towel_type, branch: branch, status: status, adjustment_quantity: quantity, reason: "test setup"
    )
  end

  it "shows the sales branch's clean balance and the laundry's dirty balance as the single Current Balance column" do
    fund(sales_branch, "clean", 50)
    fund(laundry_branch, "dirty", 30)

    # A plain viewer (no audit permission) never gets the detail breakdown,
    # so for them the Clean/Dirty labels genuinely aren't on the page at all.
    sign_in plain_viewer
    get laundry_towel_balances_path

    expect(response.body).to include(I18n.t("laundry.balances.operational_balance"))
    expect(response.body).not_to include(I18n.t("laundry.balances.clean"))
    expect(response.body).not_to include(I18n.t("laundry.balances.dirty"))

    # Both operational figures are on the page (as plain numbers in the table).
    expect(response.body).to match(/50/)
    expect(response.body).to match(/30/)
  end

  it "keeps in-transit as its own visible column, separate from the operational balance" do
    fund(sales_branch, "clean", 100)
    transfer = business.towel_transfers.create!(towel_type: towel_type, source_branch: sales_branch,
                                                destination_branch: laundry_branch, towel_status: "dirty",
                                                declared_quantity: 40)
    Laundry::TowelTransferCreator.new(transfer).dispatch(actor: owner)

    sign_in owner
    get laundry_towel_balances_path

    expect(response.body).to include(I18n.t("laundry.balances.in_transit_out"))
    expect(response.body).to match(/40/) # in transit
    expect(response.body).to match(/60/) # remaining clean balance at the sales branch (100 - 40)
  end

  it "shows the Details toggle and full clean/dirty/damaged/disposed/lost breakdown to an authorized auditor" do
    fund(laundry_branch, "dirty", 10)
    fund(laundry_branch, "clean", 5) # the edge case — a stray clean balance at the laundry

    sign_in auditor
    get laundry_towel_balances_path

    expect(response.body).to include(I18n.t("laundry.balances.details"))
    expect(response.body).to include(I18n.t("laundry.balances.clean"))
    expect(response.body).to include(I18n.t("laundry.balances.dirty"))
    expect(response.body).to include(I18n.t("laundry.balances.damaged"))
    expect(response.body).to include(I18n.t("laundry.balances.disposed"))
    expect(response.body).to include(I18n.t("laundry.balances.lost"))
    # The edge case is flagged, not silently dropped from the main balance.
    expect(response.body).to include(I18n.t("laundry.balances.unexpected_balance_hint"))
  end

  it "hides the Details toggle from a plain operational viewer" do
    fund(laundry_branch, "dirty", 10)

    sign_in plain_viewer
    get laundry_towel_balances_path

    expect(response.body).not_to include(I18n.t("laundry.balances.details"))
  end

  it "does not flag the badge when only the location-implied status has a balance" do
    fund(sales_branch, "clean", 50) # normal — no dirty at a sales branch

    sign_in auditor
    get laundry_towel_balances_path

    expect(response.body).not_to include(I18n.t("laundry.balances.unexpected_balance_hint"))
  end
end
