require "rails_helper"

# Warehouse Access hardening, Phase 2 (A) at the HTTP layer: the employee
# form's warehouse field needs manage_warehouse_access, and a crafted request
# can neither escalate beyond the editor's own reach nor touch their own access.
RSpec.describe "Employee form warehouse access", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:main_wh)  { business.warehouses.create!(name: "Main Store") }
  let!(:other_wh) { business.warehouses.create!(name: "Other Store") }
  let(:employee)  { create(:user, business: business) }

  def editor(*extra)
    role = business.permission_roles.create!(
      name: "Editor #{SecureRandom.hex(3)}",
      permissions: %w[view_employees manage_employees view_inventory] + extra.map(&:to_s),
      permission_scopes: { "view_employees" => "business", "manage_employees" => "business" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def submit(user, ids) = patch(admin_user_path(user), params: { user: { assigned_warehouse_ids: [ "" ] + ids.map(&:to_s) } })
  def assigned(user = employee) = WarehouseAssignment.where(user: user).order(:warehouse_id).pluck(:warehouse_id)

  it "applies the change for a manage_warehouse_access holder" do
    sign_in editor(:manage_warehouse_access)
    submit(employee, [ main_wh.id ])

    expect(assigned).to eq([ main_wh.id ])
  end

  it "ignores the field for a manage_employees holder without it (and does not offer it)" do
    hr = editor
    sign_in hr
    get edit_admin_user_path(employee)
    expect(response.body).not_to include("user[assigned_warehouse_ids]")

    submit(employee, [ main_wh.id ])
    expect(assigned).to be_empty
  end

  it "refuses a crafted grant outside the editor's reach and writes nothing" do
    admin = editor(:manage_warehouse_access)
    WarehouseAssignment.create!(user: admin, warehouse: main_wh)
    sign_in admin

    get edit_admin_user_path(employee)
    expect(response.body).to include("Main Store")
    expect(response.body).not_to include("Other Store")

    expect { submit(employee, [ main_wh.id, other_wh.id ]) }.not_to change(WarehouseAssignment, :count)
    expect(response).to redirect_to(root_path)
  end

  it "never changes the editor's own access" do
    admin = editor(:manage_warehouse_access)
    sign_in admin
    submit(admin, [ main_wh.id ])

    expect(assigned(admin)).to be_empty
  end
end
