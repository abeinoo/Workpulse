require "rails_helper"

# D1 — the Organization & Access account-management interface. Request-level
# behaviour (who may change what, through which screen) stays pinned by
# spec/characterization/organization_access/account_field_writes_spec.rb and the
# security suites; this spec covers the interface's own invariants.
RSpec.describe OrganizationAccess::Accounts do
  let(:business)  { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let(:actor)     { create(:user, business: business) }
  let(:employee)  { create(:user, business: business, email: "e@example.com") }
  let(:foreigner) { create(:user, business: create(:business)) }

  it "owns exactly the status and login-identifier columns" do
    expect(described_class::FIELDS).to eq(%w[active email phone_number])
    expect(UserPolicy::LOGIN_ATTRIBUTES.map(&:to_s)).to eq(described_class::LOGIN_FIELDS)
    expect(UserPolicy::ACCOUNT_ATTRIBUTES).to include(:active)
  end

  describe ".build" do
    it "builds an unsaved account row in the business with its login identifiers" do
      user = described_class.build(business_id: business.id, login: { phone_number: "01000000011" })
      expect(user).to be_new_record
      expect(user).to have_attributes(business_id: business.id, phone_number: "01000000011", email: nil)
    end

    it "refuses a non-login field and a missing business" do
      expect { described_class.build(business_id: business.id, login: { active: false }) }
        .to raise_error(described_class::Refused)
      expect { described_class.build(business_id: nil) }.to raise_error(described_class::Refused)
    end
  end

  describe ".stage" do
    it "assigns account fields without saving" do
      described_class.stage(actor: actor, user: employee, attributes: { "email" => "n@example.com", "active" => "0" })
      expect(employee).to have_attributes(email: "n@example.com", active: false)
      expect(employee.reload.email).to eq("e@example.com")
    end

    it "is a no-op for no account fields" do
      expect(described_class.stage(actor: actor, user: foreigner, attributes: {})).to equal(foreigner)
    end

    it "refuses a non-account field, another business's account and the owner's status" do
      expect { described_class.stage(actor: actor, user: employee, attributes: { first_name: "X" }) }
        .to raise_error(described_class::Refused)
      expect { described_class.stage(actor: actor, user: foreigner, attributes: { email: "x@example.com" }) }
        .to raise_error(described_class::Refused)
      expect { described_class.stage(actor: owner, user: owner, attributes: { active: "0" }) }
        .to raise_error(described_class::Refused)
      expect(foreigner.reload.email).not_to eq("x@example.com")
    end
  end

  describe ".stage_role" do
    let(:role_admin) do
      role = create(:permission_role, business: business, permissions: %w[view_employees manage_employees manage_roles],
                                      permission_scopes: { "manage_employees" => "business" })
      create(:user, business: business, permission_role: role)
    end
    let(:small_role) { create(:permission_role, business: business, permissions: %w[view_employees]) }

    it "stages an allowed role, refuses an escalation, and treats an unchanged role as allowed" do
      expect(described_class.stage_role(actor: role_admin, user: employee, role_id: small_role.id.to_s)).to be_allowed
      expect(employee.permission_role).to eq(small_role)
      expect(employee.reload.permission_role_id).to be_nil

      escalation = create(:permission_role, business: business, permissions: %w[manage_roles manage_employees view_employees manage_branches])
      expect(described_class.stage_role(actor: role_admin, user: employee, role_id: escalation.id)).not_to be_allowed
      expect(described_class.stage_role(actor: role_admin, user: employee.reload, role_id: nil)).to be_allowed
    end

    it "refuses another business's account" do
      expect { described_class.stage_role(actor: role_admin, user: foreigner, role_id: small_role.id) }
        .to raise_error(described_class::Refused)
    end
  end

  describe ".toggle_active!" do
    it "flips and persists the status, returning it" do
      expect(described_class.toggle_active!(actor: actor, user: employee)).to be(false)
      expect(employee.reload.active).to be(false)
      expect(described_class.toggle_active!(actor: actor, user: employee)).to be(true)
    end

    it "refuses the owner and another business's account, writing nothing" do
      expect { described_class.toggle_active!(actor: actor, user: owner) }.to raise_error(described_class::Refused)
      expect { described_class.toggle_active!(actor: actor, user: foreigner) }.to raise_error(described_class::Refused)
      expect([ owner.reload.active, foreigner.reload.active ]).to eq([ true, true ])
    end

    it "writes no audit row (none existed before D1)" do
      expect { described_class.toggle_active!(actor: actor, user: employee) }
        .not_to change { [ AuditLog.count, UserAuditLog.count ] }
    end
  end

  describe ".transfer_ownership!" do
    it "moves the actor's business ownership; refuses another business's account" do
      described_class.transfer_ownership!(actor: owner, user: employee)
      expect(business.reload.owner_id).to eq(employee.id)
      expect { described_class.transfer_ownership!(actor: employee, user: foreigner) }.to raise_error(described_class::Refused)
    end
  end
end
