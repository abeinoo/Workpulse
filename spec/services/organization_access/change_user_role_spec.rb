require "rails_helper"

RSpec.describe OrganizationAccess::ChangeUserRole, type: :model do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:actor) do
    role = create(:permission_role, business: business, permissions: %w[view_attendance manage_roles],
                                    permission_scopes: { "view_attendance" => "business" })
    create(:user, business: business, permission_role: role)
  end
  let(:target) { create(:user, business: business) }
  let(:within) { create(:permission_role, business: business, permissions: %w[view_attendance]) }
  let(:above)  { create(:permission_role, business: business, permissions: %w[view_attendance view_payroll]) }

  def change_role(user_id: target.id, role_id:)
    described_class.new(user_id, actor: actor, role_id: role_id).call
  end

  it "assigns a permitted role and persists it" do
    result = change_role(role_id: within.id)
    expect(result.ok?).to be(true)
    expect(result.record).to eq(target)
    expect(target.reload.permission_role).to eq(within)
  end

  it "removes the role (role_id nil)" do
    target.update!(permission_role: within)
    expect(change_role(role_id: nil).ok?).to be(true)
    expect(target.reload.permission_role).to be_nil
  end

  it "refuses an escalating role and leaves the user unchanged" do
    result = change_role(role_id: above.id)
    expect([ result.ok?, result.error ]).to eq([ false, :not_authorized ])
    expect(target.reload.permission_role).to be_nil
  end

  it "refuses a role of another business" do
    foreign = create(:permission_role, business: create(:business), permissions: %w[view_attendance])
    expect(change_role(role_id: foreign.id).error).to eq(:not_authorized)
    expect(target.reload.permission_role).to be_nil
  end

  it "never targets a user of another business (RecordNotFound, as the controller find did)" do
    stranger = create(:user, business: create(:business))
    expect { change_role(user_id: stranger.id, role_id: within.id) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "refuses the owner and the actor themselves" do
    expect(change_role(user_id: owner.id, role_id: within.id).error).to eq(:not_authorized)
    expect(change_role(user_id: actor.id, role_id: within.id).error).to eq(:not_authorized)
    expect(owner.reload.permission_role).to be_nil
  end

  it "writes no audit record (plan D1)" do
    expect { change_role(role_id: within.id) }.not_to change { [ AuditLog.count, UserAuditLog.count ] }
  end
end
