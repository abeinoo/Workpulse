require "rails_helper"

# PermissionRole pilot, Step 7A: the model lives physically in Organization &
# Access (app/models/organization_access/, a collapsed directory) but keeps its
# top-level constant and table — 16 historical data migrations, the factory and
# the User/Business associations depend on both. Guards against an accidental
# un-collapse or rename.
RSpec.describe "Architecture: PermissionRole location" do
  it "loads as the top-level PermissionRole from app/models/organization_access/" do
    expect(PermissionRole.name).to eq("PermissionRole") # triggers the autoload first
    path = Object.const_source_location(:PermissionRole).first
    expect(path).to eq(Rails.root.join("app/models/organization_access/permission_role.rb").to_s)
  end

  it "keeps permission_roles as its table" do
    expect(PermissionRole.table_name).to eq("permission_roles")
  end

  it "introduces no OrganizationAccess::PermissionRole constant" do
    expect(OrganizationAccess.const_defined?(:PermissionRole, false)).to be(false)
  end

  it "is the same class the User and Business associations resolve" do
    expect(User.reflect_on_association(:permission_role).klass).to equal(PermissionRole)
    expect(Business.reflect_on_association(:permission_roles).klass).to equal(PermissionRole)
  end
end
