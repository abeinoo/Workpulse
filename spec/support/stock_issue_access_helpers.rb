# Test setup for Stock Issue authorization: operation permissions (checked in
# the services) and warehouse access (Inventory::IssueWarehouseReach).
module StockIssueAccessHelpers
  # The prerequisites of the Stock Issue permissions (PermissionRole::PERMISSION_DEPENDENCIES).
  STOCK_ISSUE_BASE = %w[view_inventory view_stock_issues].freeze

  # A non-owner with exactly these permissions (plus the Stock Issue
  # prerequisites, so the role is valid).
  def stock_issue_user(business, *permissions)
    role = business.permission_roles.create!(name: "Stock issue role #{SecureRandom.hex(4)}",
                                             permissions: (STOCK_ISSUE_BASE + permissions.map(&:to_s)).uniq)
    create(:user, business: business).tap { |user| user.update_column(:permission_role_id, role.id) }
  end

  # The branch's own warehouse (kind "branch", as the provisioning would
  # create it). A Stock Issue from it is attributed to that branch for cost
  # (StockIssue#assign_cost_attribution_branch).
  def branch_warehouse_for(branch, name: nil)
    branch.business.warehouses.find_by(kind: "branch", branch_id: branch.id) ||
      branch.business.warehouses.create!(name: name || "#{branch.name} – WH", kind: "branch", branch: branch)
  end

  # Restricts a user to exactly these warehouses (explicit assignments — in a
  # legacy-mode business a user without any assignment reaches every warehouse).
  def restrict_to_warehouses!(user, *warehouses)
    warehouses.flatten.each { |warehouse| WarehouseAssignment.create!(user: user, warehouse: warehouse) }
    user.reload
  end

  # Every Stock Issue operation permission.
  def all_stock_issue_permissions
    %w[create_stock_issues approve_stock_issues confirm_stock_issues cancel_stock_issues void_stock_issues]
  end
end

RSpec.configure { |config| config.include StockIssueAccessHelpers }
