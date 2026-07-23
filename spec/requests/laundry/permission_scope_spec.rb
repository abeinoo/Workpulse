require "rails_helper"

# Verifies Laundry's branch-scoped permissions resolve the user's branch from
# their active ShiftAssignment — not from branch_manager_id/area_manager_id,
# which most laundry/floor staff never hold. See BranchScope's
# include_shift_assignments option and Laundry::BaseController#assignable_branches.
RSpec.describe "Laundry permission scope resolution", type: :request do
  let(:business)  { create(:business) }
  let!(:branch_a) { create(:branch, business: business, branch_type: "sales", name: "Branch A") }
  let!(:branch_b) { create(:branch, business: business, branch_type: "sales", name: "Branch B") }
  let!(:branch_c) { create(:branch, business: business, branch_type: "sales", name: "Branch C") }
  let(:area_manager)     { create(:user, business: business) }
  let(:hour_based_shift) { create(:shift, :hour_based, business: business) }

  before { business.towel_types.create!(name: "Bath Towel") }

  def role_with(scope, perms: %w[view_towel_balances])
    business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(4)}", permissions: perms,
      permission_scopes: perms.index_with { scope }
    )
  end

  # A Receptionist: purely shift-assigned, never a branch_manager_id/area_manager_id
  # anywhere — the exact profile the bug report describes.
  def receptionist(scope, branches: [])
    role = role_with(scope)
    user = create(:user, business: business)
    user.update_column(:permission_role_id, role.id)
    Array(branches).each { |b| create(:shift_assignment, user: user, branch: b, shift: hour_based_shift) }
    user
  end

  describe "branch scope" do
    it "resolves the user's branch from their active ShiftAssignment and shows only that branch's data" do
      user = receptionist("branch", branches: [ branch_a ])
      sign_in user

      get laundry_towel_transfers_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(branch_a.name)
      expect(response.body).not_to include(branch_b.name)
      expect(response.body).not_to include(branch_c.name)
    end

    it "does not grant access via branch_manager_id alone without a matching scope test — sanity check on the fixture" do
      # A user who merely manages a branch (no ShiftAssignment) still resolves via
      # the existing management-based path — this must keep working unchanged.
      manager = create(:user, business: business)
      role = role_with("branch")
      manager.update_column(:permission_role_id, role.id)
      branch_a.update!(branch_manager_id: manager.id)
      sign_in manager

      get laundry_towel_transfers_path

      expect(response.body).to include(branch_a.name)
      expect(response.body).not_to include(branch_b.name)
    end
  end

  describe "region (area) scope" do
    it "resolves every branch sharing an area manager with the user's shift-assigned branch" do
      branch_a.update!(area_manager_id: area_manager.id)
      branch_b.update!(area_manager_id: area_manager.id)
      user = receptionist("area", branches: [ branch_a ])
      sign_in user

      get laundry_towel_transfers_path

      expect(response.body).to include(branch_a.name, branch_b.name)
      expect(response.body).not_to include(branch_c.name)
    end
  end

  describe "organization (business) scope" do
    it "shows every branch in the business regardless of shift assignment" do
      user = receptionist("business", branches: [ branch_a ])
      sign_in user

      get laundry_towel_transfers_path

      expect(response.body).to include(branch_a.name, branch_b.name, branch_c.name)
    end
  end

  describe "user with multiple active shift assignments" do
    it "includes every branch from every concurrently active assignment under branch scope" do
      user = receptionist("branch", branches: [ branch_a, branch_b ])
      sign_in user

      get laundry_towel_transfers_path

      expect(response.body).to include(branch_a.name, branch_b.name)
      expect(response.body).not_to include(branch_c.name)
    end
  end

  describe "user without any active assignment" do
    it "sees no branch under branch scope (no manager role, no shift assignment)" do
      user = receptionist("branch", branches: [])
      sign_in user

      get laundry_towel_transfers_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(branch_a.name, branch_b.name, branch_c.name)
    end

    it "excludes an expired ShiftAssignment from branch scope" do
      user = receptionist("branch")
      create(:shift_assignment, user: user, branch: branch_a, shift: hour_based_shift,
             effective_from: 6.months.ago.to_date, effective_to: 1.month.ago.to_date)
      sign_in user

      get laundry_towel_transfers_path

      expect(response.body).not_to include(branch_a.name)
    end
  end

  describe "consistency across Laundry controllers and policies" do
    it "TowelTransfersController's new-form branch selector also respects branch scope via ShiftAssignment" do
      user = receptionist("branch", branches: [ branch_a ])
      role = user.permission_role
      role.update!(permissions: role.permissions + %w[create_towel_transfers],
                   permission_scopes: role.permission_scopes.merge("create_towel_transfers" => "branch"))
      sign_in user

      get new_laundry_towel_transfer_path

      expect(response.body).to include(branch_a.name)
      expect(response.body).not_to include(branch_b.name)
    end

    it "TowelTransferPolicy denies dispatch for a shift-assigned user whose branch is outside scope" do
      other_branch_manager = create(:user, business: business)
      laundry_branch = create(:branch, business: business, branch_type: "laundry")
      transfer = business.towel_transfers.create!(
        source_branch: branch_a, destination_branch: laundry_branch, towel_status: "dirty",
        items: [ TowelTransferItem.new(towel_type: business.towel_types.first, declared_quantity: 10) ]
      )

      user = receptionist("branch", branches: [ branch_b ]) # NOT branch_a — outside scope
      role = user.permission_role
      role.update!(permissions: role.permissions + %w[create_towel_transfers],
                   permission_scopes: role.permission_scopes.merge("create_towel_transfers" => "branch"))

      expect(TowelTransferPolicy.new(user, transfer).dispatch?).to be(false)
    end

    it "TowelTransferPolicy allows dispatch once the user's active ShiftAssignment matches the transfer's source branch" do
      laundry_branch = create(:branch, business: business, branch_type: "laundry")
      transfer = business.towel_transfers.create!(
        source_branch: branch_a, destination_branch: laundry_branch, towel_status: "dirty",
        items: [ TowelTransferItem.new(towel_type: business.towel_types.first, declared_quantity: 10) ]
      )

      user = receptionist("branch", branches: [ branch_a ])
      role = user.permission_role
      role.update!(permissions: role.permissions + %w[create_towel_transfers],
                   permission_scopes: role.permission_scopes.merge("create_towel_transfers" => "branch"))

      expect(TowelTransferPolicy.new(user, transfer).dispatch?).to be(true)
    end
  end
end
