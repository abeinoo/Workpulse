require "rails_helper"

# CreateRole / UpdateRole / DeleteRole (with the shared RoleGrantCheck).
RSpec.describe "OrganizationAccess role definition services", type: :model do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:other)    { create(:business) }
  let(:admin) do
    role = create(:permission_role, business: business, permissions: %w[view_attendance view_shifts manage_roles],
                                    permission_scopes: { "view_attendance" => "branch" })
    create(:user, business: business, permission_role: role)
  end

  def attrs(**overrides)
    { name: "Supervisors", permissions: %w[view_attendance], permission_scopes: { "view_attendance" => "branch" } }.merge(overrides)
  end

  describe OrganizationAccess::CreateRole do
    def create_role(by: admin, **overrides)
      described_class.new(actor: by, attributes: attrs(**overrides)).call
    end

    it "creates a valid role in the actor's business" do
      result = create_role
      expect(result.ok?).to be(true)
      expect(result.record).to be_persisted
      expect(result.record.business).to eq(business)
    end

    it "always uses the actor's business, even if business_id is supplied" do
      result = create_role(business_id: other.id)
      expect(result.record.business_id).to eq(business.id)
    end

    it "refuses invalid permissions (validation) without saving" do
      result = create_role(permissions: %w[not_a_permission])
      expect([ result.ok?, result.error ]).to eq([ false, :invalid ])
      expect(result.record).not_to be_persisted
    end

    it "refuses permissions the actor does not hold (cannot_grant)" do
      result = create_role(permissions: %w[view_attendance view_payroll])
      expect(result.error).to eq(:invalid)
      expect(result.record.errors[:permissions].join).to include("view_payroll")
    end

    it "refuses a scope broader than the actor's (scope_too_broad)" do
      result = create_role(permission_scopes: { "view_attendance" => "business" })
      expect(result.error).to eq(:invalid)
      expect(result.record.errors[:permission_scopes]).to be_present
    end

    it "refuses an actor without manage_roles" do
      viewer = create(:user, business: business,
                             permission_role: create(:permission_role, business: business, permissions: %w[view_attendance]))
      expect(create_role(by: viewer).error).to eq(:not_authorized)
    end

    it "lets the owner create any valid role" do
      result = create_role(by: owner, permissions: %w[view_attendance view_payroll], permission_scopes: { "view_attendance" => "business" })
      expect(result.ok?).to be(true)
    end
  end

  describe OrganizationAccess::UpdateRole do
    let(:role) { create(:permission_role, business: business, permissions: %w[view_attendance], permission_scopes: { "view_attendance" => "branch" }) }

    def update_role(id: role.id, by: admin, **attributes)
      described_class.new(id, actor: by, attributes: attributes).call
    end

    it "updates a manageable role" do
      expect(update_role(permissions: %w[view_attendance view_shifts]).ok?).to be(true)
      expect(role.reload.permissions).to eq(%w[view_attendance view_shifts])
    end

    it "refuses adding a permission the actor lacks, leaving the role unchanged" do
      result = update_role(permissions: %w[view_attendance view_payroll])
      expect(result.error).to eq(:invalid)
      expect(role.reload.permissions).to eq(%w[view_attendance])
    end

    it "refuses widening a scope beyond the actor's" do
      expect(update_role(permission_scopes: { "view_attendance" => "business" }).error).to eq(:invalid)
      expect(role.reload.scope_for(:view_attendance)).to eq("branch")
    end

    it "refuses invalid permissions" do
      expect(update_role(permissions: %w[not_a_permission]).error).to eq(:invalid)
    end

    it "refuses a role the actor cannot manage (holds permissions above the actor)" do
      above = create(:permission_role, business: business, permissions: %w[view_attendance view_payroll])
      expect(update_role(id: above.id, name: "Renamed").error).to eq(:not_authorized)
      expect(above.reload.name).not_to eq("Renamed")
    end

    it "never loads a role of another business" do
      foreign = create(:permission_role, business: other, permissions: %w[view_attendance])
      expect { update_role(id: foreign.id, name: "x") }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe OrganizationAccess::DeleteRole do
    def delete_role(id, by: admin) = described_class.new(id, actor: by).call

    let(:manageable) { { permissions: %w[view_attendance], permission_scopes: { "view_attendance" => "branch" } } }

    it "deletes a manageable role without users" do
      role = create(:permission_role, business: business, **manageable)
      expect(delete_role(role.id).ok?).to be(true)
      expect(PermissionRole.exists?(role.id)).to be(false)
    end

    it "never deletes a role that still has users" do
      role = create(:permission_role, business: business, **manageable)
      create(:user, business: business, permission_role: role)
      expect(delete_role(role.id).error).to eq(:has_users)
      expect(PermissionRole.exists?(role.id)).to be(true)
    end

    it "refuses a role the actor cannot manage (a blank scope ranks as area, broader than the actor's branch)" do
      above = create(:permission_role, business: business, permissions: %w[view_attendance])
      expect(delete_role(above.id).error).to eq(:not_authorized)
      expect(PermissionRole.exists?(above.id)).to be(true)
    end

    it "never loads a role of another business" do
      foreign = create(:permission_role, business: other)
      expect { delete_role(foreign.id) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
