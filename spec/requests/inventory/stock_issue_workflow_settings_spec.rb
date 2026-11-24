require "rails_helper"

RSpec.describe "Stock Issue workflow settings", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  it "lets the owner change each workflow's setting" do
    sign_in owner
    get inventory_stock_issue_workflow_settings_path
    expect(response).to have_http_status(:ok)

    patch inventory_stock_issue_workflow_settings_path,
          params: { stock_issue_workflow_settings: { self_approval: "allowed", quick_issue_enabled: "0" } }
    expect(response).to redirect_to(inventory_stock_issue_workflow_settings_path)
    business.reload
    expect(business.stock_issue_self_approval).to eq("allowed")
    expect(business.quick_issue_enabled?).to be false
  end

  it "is refused to non-owners, whatever their permissions" do
    admin = create(:user, business: business)
    role  = business.permission_roles.create!(name: "Admin", permissions: %w[manage_settings view_inventory manage_inventory])
    admin.update_column(:permission_role_id, role.id)
    sign_in admin

    patch inventory_stock_issue_workflow_settings_path,
          params: { stock_issue_workflow_settings: { self_approval: "allowed", quick_issue_enabled: "0" } }
    expect(response).to redirect_to(root_path).or have_http_status(:forbidden)
    expect(business.reload.stock_issue_self_approval).to eq("forbidden")
  end
end
