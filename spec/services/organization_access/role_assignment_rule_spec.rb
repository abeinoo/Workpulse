require "rails_helper"

RSpec.describe OrganizationAccess::RoleAssignmentRule, type: :model do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:actor)    { user_with(%w[view_attendance view_shifts manage_roles], scopes: { "view_attendance" => "business" }) }
  let(:target)   { create(:user, business: business) }

  def user_with(permissions, scopes: {})
    role = create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes)
    create(:user, business: business, permission_role: role)
  end

  def role_with(permissions, scopes: {}, in_business: business)
    create(:permission_role, business: in_business, permissions: permissions, permission_scopes: scopes)
  end

  def decide(user: target, role_id:, by: actor)
    described_class.decide(actor: by, user: user, role_id: role_id)
  end

  it "allows a role within the actor's permissions and scopes, returning that role" do
    role = role_with(%w[view_attendance], scopes: { "view_attendance" => "branch" })
    decision = decide(role_id: role.id)
    expect(decision.allowed?).to be(true)
    expect(decision.role).to eq(role)
  end

  it "accepts the role id as a String (form params)" do
    role = role_with(%w[view_attendance])
    expect(decide(role_id: role.id.to_s).role).to eq(role)
  end

  it "treats a blank role id as removing the role" do
    target.update!(permission_role: role_with(%w[view_attendance]))
    [ nil, "" ].each do |blank|
      decision = decide(role_id: blank)
      expect([ decision.allowed?, decision.role ]).to eq([ true, nil ])
    end
  end

  it "denies a role holding a permission the actor lacks (escalation)" do
    expect(decide(role_id: role_with(%w[view_attendance view_payroll]).id).allowed?).to be(false)
  end

  it "denies a role granting a broader scope than the actor's" do
    branch_actor = user_with(%w[view_attendance manage_roles], scopes: { "view_attendance" => "branch" })
    wide = role_with(%w[view_attendance], scopes: { "view_attendance" => "business" })
    expect(decide(role_id: wide.id, by: branch_actor).allowed?).to be(false)
  end

  it "denies taking a user away from a role above the actor" do
    target.update!(permission_role: role_with(%w[view_attendance view_payroll]))
    expect(decide(role_id: nil).allowed?).to be(false)
  end

  it "denies a role of another business, without resolving it" do
    foreign = role_with(%w[view_attendance], in_business: create(:business))
    decision = decide(role_id: foreign.id)
    expect([ decision.allowed?, decision.role ]).to eq([ false, nil ])
  end

  it "denies an unknown role id" do
    expect(decide(role_id: 0).allowed?).to be(false)
  end

  it "denies self-assignment, the owner as target, and an actor without manage_roles" do
    role = role_with(%w[view_attendance])
    expect(decide(user: actor, role_id: role.id).allowed?).to be(false)
    expect(decide(user: owner, role_id: role.id).allowed?).to be(false)
    expect(decide(role_id: role.id, by: user_with(%w[view_attendance])).allowed?).to be(false)
  end

  it "lets the owner assign any role of the business to another user" do
    full = create(:permission_role, :full_access, business: business)
    expect(decide(role_id: full.id, by: owner).allowed?).to be(true)
  end
end
