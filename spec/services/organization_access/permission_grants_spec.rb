require "rails_helper"

# Step 4 (PermissionRole pilot): PermissionGrants now lives in Organization &
# Access. The full decision table is characterized against the legacy name in
# spec/characterization/organization_access/permission_grants_spec.rb, which
# calls this module directly since the legacy alias was removed (Step 6). The
# examples here cover what that table does not: the complete scope-breadth
# matrix, changing an existing role, and the module's business-agnostic
# contract (isolation is enforced by its callers — see the OA-S2 security specs).
RSpec.describe OrganizationAccess::PermissionGrants, type: :model do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  def user_with(permissions, scopes: {}, in_business: business)
    role = create(:permission_role, business: in_business, permissions: permissions, permission_scopes: scopes)
    create(:user, business: in_business, permission_role: role)
  end

  def role_with(permissions, scopes: {}, in_business: business)
    create(:permission_role, business: in_business, permissions: permissions, permission_scopes: scopes)
  end

  describe "location and compatibility" do
    it "the legacy top-level PermissionGrants alias no longer exists (removed in Step 6)" do
      expect(Object.const_defined?(:PermissionGrants)).to be(false)
    end

    it "keeps its public interface and constants" do
      expect(described_class).to respond_to(:administrative_permissions, :covers?, :grantable_permissions,
                                            :ungrantable, :scope_rank, :overbroad_scopes, :manageable_role?,
                                            :can_change_role?)
      expect(described_class::ADMINISTRATIVE_PERMISSIONS)
        .to eq(%w[manage_roles manage_employees manage_settings manage_branches])
      expect(described_class::SCOPE_RANK).to eq("self" => 0, "branch" => 1, "area" => 2, "business" => 3)
      expect(described_class::DEFAULT_SCOPE_RANK).to eq(2)
    end
  end

  describe "scope breadth matrix (overbroad_scopes)" do
    # actor's own scope for view_attendance → role scopes that are overbroad.
    # A blank scope ranks as area on both sides.
    {
      "self"     => %w[branch area business] + [ nil ],
      "branch"   => %w[area business] + [ nil ],
      "area"     => %w[business],
      nil        => %w[business],
      "business" => []
    }.each do |actor_scope, overbroad_role_scopes|
      it "an actor scoped #{actor_scope.inspect} may grant only scopes up to its own" do
        actor = user_with(%w[view_attendance manage_roles],
                          scopes: actor_scope ? { "view_attendance" => actor_scope } : {})
        result = ([ nil ] + %w[self branch area business]).select do |role_scope|
          role = role_with(%w[view_attendance], scopes: role_scope ? { "view_attendance" => role_scope } : {})
          described_class.overbroad_scopes(actor, role).any?
        end
        expect(result).to match_array(overbroad_role_scopes)
      end
    end

    it "normalizes legacy scope names on both sides" do
      actor = user_with(%w[view_attendance manage_roles], scopes: { "view_attendance" => "branch_only" })
      role  = role_with(%w[view_attendance], scopes: { "view_attendance" => "business_wide" })
      expect(described_class.overbroad_scopes(actor, role)).to eq(%w[view_attendance])
    end
  end

  describe "changing an existing role (can_change_role?)" do
    let(:actor)  { user_with(%w[view_attendance view_shifts manage_roles], scopes: { "view_attendance" => "business" }) }
    let(:target) { create(:user, business: business) }

    it "allows moving between two roles within the actor's authority" do
      from = role_with(%w[view_attendance])
      to   = role_with(%w[view_attendance view_shifts])
      expect(described_class.can_change_role?(actor: actor, target: target, from: from, to: to)).to be(true)
    end

    it "denies moving to a broader role, and moving away from one" do
      within = role_with(%w[view_attendance])
      broader = role_with(%w[view_attendance view_payroll])
      expect(described_class.can_change_role?(actor: actor, target: target, from: within, to: broader)).to be(false)
      expect(described_class.can_change_role?(actor: actor, target: target, from: broader, to: within)).to be(false)
    end

    it "denies a role whose scope is broader than the actor's, even with the same permissions" do
      branch_actor = user_with(%w[view_attendance manage_roles], scopes: { "view_attendance" => "branch" })
      wide = role_with(%w[view_attendance], scopes: { "view_attendance" => "business" })
      expect(described_class.can_change_role?(actor: branch_actor, target: target, from: nil, to: wide)).to be(false)
    end

    it "denies self-assignment even for an otherwise permitted role" do
      expect(described_class.can_change_role?(actor: actor, target: actor, from: actor.permission_role, to: nil)).to be(false)
    end
  end

  # Existing contract: the module decides on permissions and scopes only. It does
  # NOT check businesses — callers resolve roles and users through
  # current_user.business (404 otherwise) and User validates its role's business.
  # These examples pin that split so the isolation responsibility is not lost.
  describe "business isolation responsibility (callers + model, not this module)" do
    let(:actor)        { user_with(%w[view_attendance manage_roles], scopes: { "view_attendance" => "business" }) }
    let(:other)        { create(:business) }
    let(:foreign_role) { role_with(%w[view_attendance], in_business: other) }

    it "does not itself reject a role of another business" do
      target = create(:user, business: business)
      expect(described_class.can_change_role?(actor: actor, target: target, from: nil, to: foreign_role)).to be(true)
    end

    it "the User model rejects that role, so no write path can persist it" do
      target = create(:user, business: business)
      expect(target.update(permission_role: foreign_role)).to be(false)
      expect(target.errors[:permission_role]).to be_present
    end

    it "does not itself reject a target user of another business" do
      expect(described_class.covers?(actor, create(:user, business: other))).to be(true)
    end
  end
end
