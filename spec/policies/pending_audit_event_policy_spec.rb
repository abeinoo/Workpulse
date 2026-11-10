require "rails_helper"

# R3.1 business audit-failure dashboard authorization (§6.8, G2, D30).
RSpec.describe PendingAuditEventPolicy do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  def user_with(permissions, in_business: business)
    role = create(:permission_role, business: in_business, permissions: permissions)
    create(:user, business: in_business, permission_role: role)
  end

  let(:monitor) { user_with(%w[monitor_audit_failures]) }
  let(:owner)   { create(:user, business: business).tap { |u| business.update!(owner: u) } }
  let(:admin)   { user_with(%w[manage_roles manage_settings view_payroll view_payroll_audit_log]) }

  let!(:own_event)   { create(:pending_audit_event, actor: create(:user, business: business)) }
  let!(:other_event) { create(:pending_audit_event, actor: create(:user, business: other)) }

  it "admits holders of monitor_audit_failures and the owner, nobody else" do
    expect(described_class.new(monitor, PendingAuditEvent).index?).to be(true)
    expect(described_class.new(owner, PendingAuditEvent).index?).to be(true)
    expect(described_class.new(admin, PendingAuditEvent).index?).to be(false)
  end

  it "scopes to the user's own business in the database" do
    expect(described_class::Scope.new(monitor, PendingAuditEvent).resolve).to contain_exactly(own_event)
    expect(described_class::Scope.new(owner, PendingAuditEvent).resolve).to contain_exactly(own_event)
    expect(described_class::Scope.new(monitor, PendingAuditEvent).resolve.to_sql).to include('"business_id" =')
  end

  it "returns nothing to a user without the permission" do
    expect(described_class::Scope.new(admin, PendingAuditEvent).resolve).to be_empty
  end

  it "refuses another business's event even when it is passed directly" do
    expect(described_class.new(monitor, other_event).show?).to be(false)
    expect(described_class.new(monitor, own_event).show?).to be(true)
  end

  it "is never part of a role preset" do
    presets = PermissionRole::DEFAULT_PERMISSIONS_BY_ROLE_TYPE.values.flatten
    expect(presets).not_to include("monitor_audit_failures")
    expect(PermissionRole::PERMISSION_GROUPS[:administration]).to include("monitor_audit_failures")
    expect(PermissionRole::SCOPABLE_PERMISSIONS).not_to include("monitor_audit_failures")
  end
end
