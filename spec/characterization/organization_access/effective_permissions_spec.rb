require "rails_helper"

# Characterization (PermissionRole pilot, Step 1 gap G7) — User#can? is the
# authorization entry point used by every domain (~570 call sites). Callers pass
# both Symbols and Strings (e.g. EmployeeDataRequestPolicy#index? iterates the
# String members of a permission group). The pilot will re-route the body of
# can?; these results must not change.
RSpec.describe "Characterization: effective permissions (User#can?)", type: :model do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:holder) do
    create(:user, business: business,
                  permission_role: create(:permission_role, business: business, permissions: %w[view_attendance view_shifts]))
  end
  let(:no_role) { create(:user, business: business) }

  it "a role holder gets the same answer for a String and a Symbol" do
    expect([ holder.can?(:view_attendance), holder.can?("view_attendance") ]).to eq([ true, true ])
    expect([ holder.can?(:view_payroll),    holder.can?("view_payroll") ]).to eq([ false, false ])
  end

  it "a user without a role is denied for both forms" do
    expect([ no_role.can?(:view_attendance), no_role.can?("view_attendance") ]).to eq([ false, false ])
  end

  it "the owner is granted for both forms" do
    expect([ owner.can?(:view_payroll), owner.can?("view_payroll") ]).to eq([ true, true ])
  end

  it "an unknown permission name is false for a role holder and a user without a role" do
    expect([ holder.can?(:not_a_permission), holder.can?("not_a_permission") ]).to eq([ false, false ])
    expect(no_role.can?(:not_a_permission)).to be(false)
  end

  # Existing behaviour: the owner short-circuit returns true before any catalogue
  # lookup, so even a name that is not a permission is "granted" to the owner.
  it "the owner is granted even an unknown permission name (existing behaviour)" do
    expect([ owner.can?(:not_a_permission), owner.can?("not_a_permission") ]).to eq([ true, true ])
  end
end
