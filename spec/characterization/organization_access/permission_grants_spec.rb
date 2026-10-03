require "rails_helper"

# Characterization (PermissionRole pilot, Step 1 gap G1) — the CURRENT decisions
# made by PermissionGrants, now OrganizationAccess::PermissionGrants
# (app/services/organization_access/permission_grants.rb; the top-level alias
# was removed in Step 6). These examples must keep passing unchanged.
# Request-level behaviour built on these rules is in
# spec/requests/security/organization_access_*_spec.rb.
RSpec.describe "Characterization: PermissionGrants decisions", type: :model do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:grants)   { OrganizationAccess::PermissionGrants }

  def user_with(permissions, scopes: {})
    role = create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes)
    create(:user, business: business, permission_role: role)
  end

  def role_with(permissions, scopes: {})
    create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes)
  end

  let(:no_role) { create(:user, business: business) }

  describe ".administrative_permissions" do
    it "is the full administrative set for the owner" do
      expect(grants.administrative_permissions(owner))
        .to eq(%w[manage_roles manage_employees manage_settings manage_branches])
    end

    it "is the intersection of the role's permissions with the administrative set" do
      user = user_with(%w[manage_roles view_attendance view_employees manage_employees])
      expect(grants.administrative_permissions(user)).to eq(%w[manage_roles manage_employees])
    end

    it "is empty without a role" do
      expect(grants.administrative_permissions(no_role)).to eq([])
    end

    it "does not treat an unsaved user in an ownerless business as the owner" do
      ownerless = create(:business)
      expect(grants.administrative_permissions(User.new(business: ownerless))).to eq([])
    end
  end

  describe ".covers? (privilege hierarchy)" do
    it "the owner covers everyone, including themselves" do
      expect(grants.covers?(owner, user_with(%w[manage_roles manage_settings]))).to be(true)
      expect(grants.covers?(owner, owner)).to be(true)
    end

    it "nobody but the owner covers the owner, even with every administrative permission" do
      admin = user_with(%w[manage_roles view_employees manage_employees manage_settings manage_branches])
      expect(grants.covers?(admin, owner)).to be(false)
    end

    it "covers a target whose administrative permissions are a subset of the actor's" do
      actor = user_with(%w[view_employees manage_employees manage_roles])
      expect(grants.covers?(actor, user_with(%w[view_employees manage_employees]))).to be(true)
      expect(grants.covers?(actor, no_role)).to be(true)
    end

    it "does not cover a target holding an administrative permission the actor lacks" do
      actor = user_with(%w[view_employees manage_employees])
      expect(grants.covers?(actor, user_with(%w[manage_settings]))).to be(false)
    end

    it "ignores non-administrative permissions when ranking" do
      actor = user_with(%w[view_employees manage_employees])
      expect(grants.covers?(actor, user_with(%w[view_attendance view_payroll]))).to be(true)
    end

    it "covers an unsaved user in an ownerless business (not mistaken for the owner)" do
      actor = user_with(%w[view_employees manage_employees])
      expect(grants.covers?(actor, User.new(business: create(:business)))).to be(true)
    end
  end

  describe ".grantable_permissions / .ungrantable" do
    it "the owner may grant every permission in the catalogue" do
      expect(grants.grantable_permissions(owner)).to eq(PermissionRole::ALL_PERMISSIONS)
      expect(grants.ungrantable(owner, PermissionRole::ALL_PERMISSIONS)).to eq([])
    end

    it "a role holder may grant exactly their role's permissions" do
      actor = user_with(%w[view_attendance view_shifts])
      expect(grants.grantable_permissions(actor)).to eq(%w[view_attendance view_shifts])
    end

    it "a user without a role may grant nothing" do
      expect(grants.grantable_permissions(no_role)).to eq([])
      expect(grants.ungrantable(no_role, %w[view_attendance])).to eq(%w[view_attendance])
    end

    it "returns the requested permissions the actor lacks, normalizing symbols and dropping blanks" do
      actor = user_with(%w[view_attendance])
      expect(grants.ungrantable(actor, [ :view_attendance, :view_payroll, "", nil, "view_shifts" ]))
        .to eq(%w[view_payroll view_shifts])
    end
  end

  describe ".scope_rank" do
    it "ranks self < branch < area < business" do
      expect(%w[self branch area business].map { |s| grants.scope_rank(s) }).to eq([ 0, 1, 2, 3 ])
    end

    it "ranks a blank scope (hierarchy default) as area" do
      expect([ nil, "" ].map { |s| grants.scope_rank(s) }).to eq([ 2, 2 ])
    end

    it "normalizes legacy scope names before ranking" do
      expect(%w[self_only branch_only business_wide].map { |s| grants.scope_rank(s) }).to eq([ 0, 1, 3 ])
    end

    it "ranks an unknown value as area" do
      expect(grants.scope_rank("galaxy")).to eq(2)
    end
  end

  describe ".overbroad_scopes" do
    let(:actor) { user_with(%w[view_attendance view_employees manage_roles], scopes: { "view_attendance" => "branch", "view_employees" => "business" }) }

    it "reports scopable permissions granted broader than the actor's own scope" do
      role = role_with(%w[view_attendance], scopes: { "view_attendance" => "business" })
      expect(grants.overbroad_scopes(actor, role)).to eq(%w[view_attendance])
    end

    it "accepts equal or narrower scopes" do
      expect(grants.overbroad_scopes(actor, role_with(%w[view_attendance], scopes: { "view_attendance" => "branch" }))).to eq([])
      expect(grants.overbroad_scopes(actor, role_with(%w[view_employees], scopes: { "view_employees" => "self" }))).to eq([])
    end

    it "treats a blank role scope as area — broader than a branch-scoped actor" do
      expect(grants.overbroad_scopes(actor, role_with(%w[view_attendance]))).to eq(%w[view_attendance])
    end

    it "never reports non-scopable permissions" do
      expect(grants.overbroad_scopes(actor, role_with(%w[manage_roles]))).to eq([])
    end

    it "is empty for the owner and for no role" do
      role = role_with(%w[view_attendance], scopes: { "view_attendance" => "business" })
      expect(grants.overbroad_scopes(owner, role)).to eq([])
      expect(grants.overbroad_scopes(actor, nil)).to eq([])
    end
  end

  describe ".manageable_role?" do
    let(:actor) { user_with(%w[view_attendance view_shifts manage_roles], scopes: { "view_attendance" => "business" }) }

    it "no role (nil) is always manageable" do
      expect(grants.manageable_role?(actor, nil)).to be(true)
    end

    it "a role within the actor's permissions and scopes is manageable" do
      expect(grants.manageable_role?(actor, role_with(%w[view_attendance], scopes: { "view_attendance" => "branch" }))).to be(true)
    end

    it "a role holding a permission the actor lacks is not" do
      expect(grants.manageable_role?(actor, role_with(%w[view_attendance view_payroll]))).to be(false)
    end

    it "a role granting a broader scope than the actor's is not" do
      narrow = user_with(%w[view_attendance manage_roles], scopes: { "view_attendance" => "branch" })
      expect(grants.manageable_role?(narrow, role_with(%w[view_attendance], scopes: { "view_attendance" => "business" }))).to be(false)
    end

    it "every role is manageable by the owner" do
      expect(grants.manageable_role?(owner, create(:permission_role, :full_access, business: business))).to be(true)
    end
  end

  describe ".can_change_role?" do
    let(:actor)  { user_with(%w[view_attendance manage_roles], scopes: { "view_attendance" => "business" }) }
    let(:target) { create(:user, business: business) }
    let(:within) { role_with(%w[view_attendance]) }
    let(:above)  { role_with(%w[view_attendance view_payroll]) }

    it "requires manage_roles" do
      no_manage = user_with(%w[view_attendance])
      expect(grants.can_change_role?(actor: no_manage, target: target, from: nil, to: nil)).to be(false)
    end

    it "allows assigning, changing and removing roles within the actor's authority" do
      expect(grants.can_change_role?(actor: actor, target: target, from: nil, to: within)).to be(true)
      expect(grants.can_change_role?(actor: actor, target: target, from: within, to: nil)).to be(true)
      expect(grants.can_change_role?(actor: actor, target: target, from: nil, to: nil)).to be(true)
    end

    it "refuses when either the current or the new role is above the actor" do
      expect(grants.can_change_role?(actor: actor, target: target, from: nil, to: above)).to be(false)
      expect(grants.can_change_role?(actor: actor, target: target, from: above, to: nil)).to be(false)
    end

    it "never targets the actor themselves" do
      expect(grants.can_change_role?(actor: actor, target: actor, from: actor.permission_role, to: within)).to be(false)
    end

    it "never targets the owner — not even for the owner" do
      expect(grants.can_change_role?(actor: actor, target: owner, from: nil, to: within)).to be(false)
      expect(grants.can_change_role?(actor: owner, target: owner, from: nil, to: within)).to be(false)
    end

    it "the owner may change any other user's role" do
      full = create(:permission_role, :full_access, business: business)
      expect(grants.can_change_role?(actor: owner, target: target, from: nil, to: full)).to be(true)
    end

    it "does not mistake an unsaved user in an ownerless business for the owner" do
      unsaved = User.new(business: create(:business))
      expect(grants.can_change_role?(actor: actor, target: unsaved, from: nil, to: within)).to be(true)
    end
  end
end
