require "rails_helper"

RSpec.describe BranchRevenuePolicy, type: :policy do
  let(:business) { create(:business) }
  let(:br1)      { create(:branch, business: business) }
  let(:br2)      { create(:branch, business: business) }

  it "lets a report viewer see ALL branches' revenue (business-wide)" do
    role = create(:permission_role, business: business, permissions: %w[view_expense_reports])
    viewer = create(:user, business: business, permission_role: role)
    r1 = create(:branch_revenue, business: business, branch: br1)
    r2 = create(:branch_revenue, business: business, branch: br2)
    expect(BranchRevenuePolicy::Scope.new(viewer, BranchRevenue).resolve).to include(r1, r2)
  end

  it "scopes a revenue manager to their own branch and blocks writing others" do
    role = create(:permission_role, business: business,
                  permissions: %w[view_expense_reports manage_branch_revenue],
                  permission_scopes: { "manage_branch_revenue" => "branch" })
    mgr = create(:user, business: business, permission_role: role)
    br1.update!(branch_manager_id: mgr.id)

    own   = build(:branch_revenue, business: business, branch: br1)
    other = build(:branch_revenue, business: business, branch: br2)
    expect(described_class.new(mgr, own).create?).to be true
    expect(described_class.new(mgr, other).create?).to be false
  end
end
