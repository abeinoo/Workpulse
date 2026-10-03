require "rails_helper"

# Characterization (PermissionRole pilot, Step 1 gaps G4, G5) — permission
# groups consumed OUTSIDE Organization & Access. Laundry builds its workspace
# gate from :laundry_operations + :laundry_cost_reports; employee onboarding
# gates its index on any :employee_onboarding permission. The pilot will route
# these lookups through a catalogue interface; membership must stay exactly as
# below (values taken from PermissionRole::PERMISSION_GROUPS as of this phase).
RSpec.describe "Characterization: permission groups consumed by other domains", type: :model do
  describe "Laundry (G4)" do
    it "laundry_operations has exactly these members, in this order" do
      expect(PermissionRole::PERMISSION_GROUPS[:laundry_operations]).to eq(%w[
        view_towel_balances create_towel_transfers confirm_towel_receipt
        adjust_towel_balances configure_towel_usage_expectations
      ])
    end

    it "laundry_cost_reports has exactly these members, in this order" do
      expect(PermissionRole::PERMISSION_GROUPS[:laundry_cost_reports]).to eq(%w[
        view_laundry_consumption_reports view_laundry_cost_reports manage_laundry_cost_settings
      ])
    end

    it "the Laundry workspace gate admits exactly the union of both groups (as symbols)" do
      expect(Laundry::BaseController::LAUNDRY_PERMISSIONS).to eq(%i[
        view_towel_balances create_towel_transfers confirm_towel_receipt
        adjust_towel_balances configure_towel_usage_expectations
        view_laundry_consumption_reports view_laundry_cost_reports manage_laundry_cost_settings
      ])
    end
  end

  describe "Employee onboarding (G5)" do
    let(:business) { create(:business) }

    # A holder of `permission` plus only the permissions it depends on (a role
    # without its dependencies cannot be saved).
    def holder_of(permission)
      perms = [ permission ]
      perms |= perms.flat_map { |p| PermissionRole::PERMISSION_DEPENDENCIES.fetch(p, []) } until
        (perms.flat_map { |p| PermissionRole::PERMISSION_DEPENDENCIES.fetch(p, []) } - perms).empty?
      role = create(:permission_role, business: business, permissions: perms)
      create(:user, business: business, permission_role: role)
    end

    it "employee_onboarding has exactly these members, in this order" do
      expect(PermissionRole::PERMISSION_GROUPS[:employee_onboarding]).to eq(%w[
        create_employee_requests view_employee_requests view_all_employee_requests
        review_employee_requests approve_employee_requests reject_employee_requests
        request_employee_changes
      ])
    end

    it "index? is granted to a holder of exactly one onboarding permission (view_employee_requests)" do
      user = holder_of("view_employee_requests")
      expect(user.permission_role.permissions).to eq(%w[view_employee_requests])
      expect(EmployeeDataRequestPolicy.new(user, EmployeeDataRequest).index?).to be(true)
    end

    it "index? is granted by every onboarding permission (with only its dependencies)" do
      PermissionRole::PERMISSION_GROUPS[:employee_onboarding].each do |permission|
        expect(EmployeeDataRequestPolicy.new(holder_of(permission), EmployeeDataRequest).index?)
          .to be(true), "expected #{permission} to grant index?"
      end
    end

    it "index? is denied without any onboarding permission" do
      outsider = create(:user, business: business,
                               permission_role: create(:permission_role, business: business, permissions: %w[view_attendance]))
      expect(EmployeeDataRequestPolicy.new(outsider, EmployeeDataRequest).index?).to be(false)
    end
  end
end
