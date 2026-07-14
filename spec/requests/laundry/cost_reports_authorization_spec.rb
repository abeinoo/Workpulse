require "rails_helper"

RSpec.describe "Laundry cost reports — authorization", type: :request do
  let(:business) { create(:business) }
  let(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:owner) { create(:user, :owner, business: business) }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms,
                                              permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

  it "lets the owner view both cost reports and the standard-cost settings screen" do
    sign_in owner

    get laundry_reports_branch_consumption_path
    expect(response).to have_http_status(:ok)

    get laundry_reports_cost_summary_path
    expect(response).to have_http_status(:ok)

    get new_laundry_towel_type_standard_cost_rate_path(towel_type)
    expect(response).to have_http_status(:ok)
  end

  it "denies an unauthorized user (no laundry permissions at all) direct access to both reports" do
    no_access = create(:user, business: business)
    sign_in no_access

    get laundry_reports_branch_consumption_path
    expect(response).to redirect_to(root_path)

    get laundry_reports_cost_summary_path
    expect(response).to redirect_to(root_path)
  end

  it "denies a user with only view_towel_balances (an operational permission) access to the cost summary report" do
    operator = user_with("view_towel_balances")
    sign_in operator

    get laundry_reports_cost_summary_path
    expect(response).to redirect_to(laundry_root_path)
  end

  it "does not expose laundry payroll cost to a laundry operator without view_laundry_cost_reports" do
    operator = user_with("view_towel_balances", "create_towel_transfers")
    sign_in operator

    get laundry_reports_cost_summary_path
    expect(response).to redirect_to(laundry_root_path)
    expect(response.body).not_to include(I18n.t("laundry.reports.cost_summary.payroll_cost"))
  end

  it "lets a branch manager view branch consumption scoped to only their own managed branch" do
    manager = user_with("view_laundry_consumption_reports")
    sales_branch.update!(branch_manager_id: manager.id)
    other_branch = create(:branch, business: business, branch_type: "sales")

    sign_in manager
    get laundry_reports_branch_consumption_path
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(other_branch.name)
  end

  it "denies a branch manager access to the business-wide cost summary report without view_laundry_cost_reports" do
    manager = user_with("view_laundry_consumption_reports")
    sales_branch.update!(branch_manager_id: manager.id)

    sign_in manager
    get laundry_reports_cost_summary_path
    expect(response).to redirect_to(laundry_root_path)
  end

  it "gates the standard cost settings screen on manage_laundry_cost_settings" do
    viewer_only = user_with("view_laundry_cost_reports")
    sign_in viewer_only

    get new_laundry_towel_type_standard_cost_rate_path(towel_type)
    expect(response).to redirect_to(root_path)
  end

  describe "cost visibility on the Towel Types page" do
    before { business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.5, effective_from: 1.day.ago) }

    it "shows neither the cost value nor the Set/Update Washing Cost action to a normal laundry worker" do
      worker = user_with("view_towel_balances")
      sign_in worker

      get laundry_towel_types_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("1.50")
      expect(response.body).not_to include(I18n.t("laundry.towel_types.update_cost"))
      expect(response.body).not_to include(I18n.t("laundry.towel_types.set_cost"))
    end

    it "shows the cost value but not the management action to a user with only view_laundry_cost_reports" do
      viewer = user_with("view_towel_balances", "view_laundry_cost_reports")
      sign_in viewer

      get laundry_towel_types_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("1.50")
      expect(response.body).not_to include(I18n.t("laundry.towel_types.update_cost"))
      expect(response.body).not_to include(I18n.t("laundry.towel_types.set_cost"))
    end

    it "shows both the cost value and the management action to a user with manage_laundry_cost_settings" do
      manager = user_with("view_towel_balances", "view_laundry_cost_reports", "manage_laundry_cost_settings")
      sign_in manager

      get laundry_towel_types_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("1.50")
      expect(response.body).to include(I18n.t("laundry.towel_types.update_cost"))
    end
  end
end
