require "rails_helper"

RSpec.describe EmployeeObligationPolicy, type: :model do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let(:employee) { create(:user, business: business) }

  # Business-wide scope configured explicitly: an unconfigured scope follows the
  # hierarchy default, not the whole business (SEC-M2-11).
  let(:manage_obligations_role) do
    create(:permission_role, permissions: %w[view_employees manage_obligations], business: business,
                             permission_scopes: { "manage_obligations" => "business" })
  end
  let(:manager_user) do
    create(:user, business: business, permission_role: manage_obligations_role)
  end

  let(:obligation) { create(:employee_obligation, user: employee, business: business, created_by: owner) }

  subject { described_class }

  describe "index?" do
    it "permits owner" do
      expect(subject).to permit(owner, obligation)
    end

    it "permits user with manage_obligations permission" do
      expect(subject).to permit(manager_user, obligation)
    end

    it "denies plain employee" do
      expect(subject).not_to permit(employee, obligation)
    end
  end

  describe "create?" do
    it "permits owner" do
      expect(subject).to permit(owner, EmployeeObligation.new(business: business))
    end

    it "permits user with manage_obligations" do
      expect(subject).to permit(manager_user, EmployeeObligation.new(business: business))
    end

    it "denies plain employee" do
      expect(subject).not_to permit(employee, EmployeeObligation.new(business: business))
    end
  end

  describe "pause? / resume? / cancel?" do
    it "permits owner to pause" do
      expect(subject).to permit(owner, obligation)
    end

    it "permits user with manage_obligations to cancel" do
      expect(subject).to permit(manager_user, obligation)
    end
  end

  describe "Scope" do
    let!(:own_obligation) do
      create(:employee_obligation, user: employee, business: business, created_by: owner)
    end

    it "returns all obligations for owner" do
      scope = EmployeeObligationPolicy::Scope.new(owner, EmployeeObligation).resolve
      expect(scope).to include(own_obligation)
    end

    it "returns obligations for user with manage_obligations" do
      scope = EmployeeObligationPolicy::Scope.new(manager_user, EmployeeObligation).resolve
      expect(scope).to include(own_obligation)
    end

    it "returns nothing for a plain employee" do
      scope = EmployeeObligationPolicy::Scope.new(employee, EmployeeObligation).resolve
      expect(scope).to be_empty
    end
  end
end
