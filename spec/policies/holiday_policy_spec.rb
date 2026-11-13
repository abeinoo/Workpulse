require "rails_helper"

# R6: manage_holidays is business-level and not scopable (D3).
RSpec.describe HolidayPolicy do
  let(:business) { create(:business) }
  let(:manager) do
    create(:user, business: business,
                  permission_role: create(:permission_role, business: business, permissions: %w[view_shifts manage_holidays]))
  end
  let(:shift_admin) do
    create(:user, business: business,
                  permission_role: create(:permission_role, business: business, permissions: %w[view_shifts manage_shifts]))
  end
  let(:holiday) { create(:holiday, created_by: manager) }

  it "lets manage_holidays holders manage the calendar" do
    policy = described_class.new(manager, holiday)
    expect(policy.update?).to be(true)
    expect(policy.destroy?).to be(true)
    expect(described_class.new(manager, Holiday).index?).to be(true)
    expect(described_class.new(manager, Holiday).create?).to be(true)
  end

  it "refuses everyone else, managing shift types included" do
    expect(described_class.new(shift_admin, Holiday).index?).to be(false)
    expect(described_class.new(shift_admin, holiday).update?).to be(false)
  end

  it "refuses another business's holiday" do
    other = create(:holiday, created_by: create(:user, business: create(:business)))
    expect(described_class.new(manager, other).update?).to be(false)
  end

  it "scopes to the user's business" do
    holiday
    create(:holiday, created_by: create(:user, business: create(:business)))
    expect(described_class::Scope.new(manager, Holiday).resolve).to eq([ holiday ])
  end

  it "is a business-level permission, not scopable" do
    expect(PermissionRole::PERMISSION_GROUPS[:shifts]).to include("manage_holidays")
    expect(PermissionRole::SCOPABLE_PERMISSIONS).not_to include("manage_holidays")
  end
end
