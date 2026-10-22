require "rails_helper"

# Characterization (D1 M1) — every write of an Organization & Access account
# field from the Workforce-owned employee screens and onboarding, recorded from
# the unchanged code before those writes move behind the Organization & Access
# account interface (module-boundaries.md §14.2 #7, decision D1 of 2026-10-22;
# docs/architecture/organization-access-account-interface-baseline-failures.txt).
#
# Account fields = users.active, users.email / users.phone_number (login
# identifiers), users.permission_role_id, the business membership of a new row,
# and Business#owner. Complements account_management_spec.rb (status toggle,
# ownership, creation basics) and the security suites (not repeated here).
RSpec.describe "Characterization: account-field writes (D1 M1)", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:hr) do
    api_user_with(business, :view_employees, :manage_employees, scopes: { "manage_employees" => "business" })
  end
  let(:role_admin) do
    api_user_with(business, :view_employees, :manage_employees, :manage_roles,
                  scopes: { "manage_employees" => "business" })
  end
  let(:employee) { create(:user, business: business, email: "emp@example.com", phone_number: "01000000001") }
  # Holds an administrative permission hr lacks: hr does not "cover" this account.
  let(:senior) do
    api_user_with(business, :view_employees, :manage_employees, :manage_roles,
                  scopes: { "manage_employees" => "business" }, email: "senior@example.com", phone_number: "01000000002")
  end

  def update_user(user, **attrs) = patch(admin_user_path(user), params: { user: attrs })

  describe "status toggle" do
    it "refuses the owner with its own message and changes nothing" do
      sign_in hr
      patch toggle_active_admin_user_path(owner)
      expect(response).to redirect_to(admin_users_path)
      expect(flash[:alert]).to eq(I18n.t("flash.cannot_deactivate_owner"))
      expect(owner.reload.active).to be(true)
    end

    it "refuses toggling one's own account" do
      sign_in hr
      patch toggle_active_admin_user_path(hr)
      expect(response).to redirect_to(root_path)
      expect(hr.reload.active).to be(true)
    end

    it "refuses an account the actor does not cover" do
      sign_in hr
      patch toggle_active_admin_user_path(senior)
      expect(response).to redirect_to(root_path)
      expect(senior.reload.active).to be(true)
    end

    it "deactivates and reactivates, with the matching notices" do
      sign_in hr
      patch toggle_active_admin_user_path(employee)
      expect([ employee.reload.active, flash[:notice] ])
        .to eq([ false, I18n.t("flash.user_deactivated", name: employee.full_name) ])
      patch toggle_active_admin_user_path(employee)
      expect([ employee.reload.active, flash[:notice] ])
        .to eq([ true, I18n.t("flash.user_activated", name: employee.full_name) ])
    end

    it "does not find another business's user" do
      foreign = create(:user, business: create(:business))
      sign_in hr
      patch toggle_active_admin_user_path(foreign)
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.active).to be(true)
    end
  end

  describe "the combined employee form" do
    it "a manager covering the account changes login identifiers and status with the profile" do
      sign_in hr
      update_user(employee, email: "new@example.com", phone_number: "01000000009", active: "0", first_name: "Nour")
      expect(response).to redirect_to(admin_users_path)
      expect(employee.reload).to have_attributes(email: "new@example.com", phone_number: "01000000009",
                                                 active: false, first_name: "Nour")
    end

    it "login identifiers and status of an account the actor does not cover are dropped; the profile is saved" do
      sign_in hr
      update_user(senior, email: "taken@example.com", phone_number: "01000000099", active: "0", first_name: "Changed")
      expect(response).to redirect_to(admin_users_path)
      expect(senior.reload).to have_attributes(email: "senior@example.com", phone_number: "01000000002",
                                               active: true, first_name: "Changed")
    end

    it "self-service (an administrator on their own record) changes their login identifiers but never their status" do
      sign_in hr
      update_user(hr, email: "me@example.com", phone_number: "01000000077", active: "0")
      expect(hr.reload).to have_attributes(email: "me@example.com", phone_number: "01000000077", active: true)
    end

    it "a plain employee cannot reach the form (admin gate), so changes nothing" do
      sign_in employee
      update_user(employee, email: "me@example.com")
      expect(response).to redirect_to(root_path)
      expect(employee.reload.email).to eq("emp@example.com")
    end

    it "an invalid form saves no account field" do
      sign_in hr
      update_user(employee, email: "new@example.com", active: "0", first_name: "")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.reload).to have_attributes(email: "emp@example.com", active: true)
    end

    it "a duplicate login identifier is refused and nothing is saved" do
      sign_in hr
      update_user(employee, phone_number: senior.phone_number, first_name: "Other")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.reload).to have_attributes(phone_number: "01000000001", first_name: employee.first_name)
    end

    it "a refused role change saves nothing; an allowed one is saved with the form" do
      big_role   = create(:permission_role, business: business, permissions: %w[manage_roles manage_employees view_employees])
      small_role = create(:permission_role, business: business, permissions: %w[view_employees])

      sign_in role_admin
      update_user(employee, permission_role_id: small_role.id, first_name: "Allowed")
      expect(employee.reload).to have_attributes(permission_role_id: small_role.id, first_name: "Allowed")

      sign_in hr # no manage_roles: the role field is not permitted and is ignored
      update_user(employee, permission_role_id: big_role.id, first_name: "Ignored")
      expect(employee.reload).to have_attributes(permission_role_id: small_role.id, first_name: "Ignored")

      escalation = create(:permission_role, business: business,
                                            permissions: %w[manage_roles manage_employees view_employees manage_branches])
      sign_in role_admin
      update_user(employee, permission_role_id: escalation.id, first_name: "Escalated")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(employee.reload).to have_attributes(permission_role_id: small_role.id, first_name: "Ignored")
    end

    it "creation sets login identifiers and status in the actor's business only" do
      sign_in hr
      post admin_users_path, params: { user: { first_name: "New", last_name: "Hire", email: "hire@example.com",
                                               phone_number: "01000000055", active: "0",
                                               identity_card_number: "ID-D1-0001", business_id: create(:business).id } }
      created = User.find_by!(email: "hire@example.com")
      expect(created).to have_attributes(business_id: business.id, phone_number: "01000000055", active: false,
                                         permission_role_id: nil)
      expect(created.encrypted_password).to be_blank
    end

    it "does not find another business's user" do
      foreign = create(:user, business: create(:business), email: "foreign@example.com")
      sign_in hr
      update_user(foreign, email: "stolen@example.com")
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.email).to eq("foreign@example.com")
    end
  end

  describe "ownership transfer" do
    it "refuses a transfer to oneself and leaves the owner unchanged" do
      sign_in owner
      patch transfer_ownership_admin_user_path(owner)
      expect(response).to redirect_to(root_path)
      expect(business.reload.owner_id).to eq(owner.id)
    end
  end

  describe "onboarding approval" do
    let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
    let(:manager)  { edr_manager(business: business) }
    let(:reviewer) { edr_reviewer(business: business) }
    let!(:managed_branch) do
      create(:branch, business: business).tap { |b| b.update_column(:branch_manager_id, manager.id) }
    end
    let(:request_record) do
      create(:employee_data_request, business: business, submitted_by: manager,
                                     national_id: "29501011234599", phone_number: "01001234599")
    end

    it "creates the account row in the request's business with its phone as login identifier, no password, no role" do
      result = EmployeeDataRequests::Reviewer.approve(request_id: request_record.id, actor: reviewer)
      expect(result).to be_ok
      employee = request_record.reload.employee
      expect(employee).to have_attributes(business_id: business.id, phone_number: "01001234599", email: nil,
                                          active: true, permission_role_id: nil)
      expect(employee.encrypted_password).to be_blank
    end

    it "refuses a phone already used as a login identifier, creating nothing" do
      request_record && reviewer
      create(:user, business: create(:business), phone_number: "01001234599")
      expect { EmployeeDataRequests::Reviewer.approve(request_id: request_record.id, actor: reviewer) }
        .not_to change(User, :count)
      expect(request_record.reload).not_to be_approved
    end

    it "validates a revision with the same account rules (duplicate phone is invalid)" do
      revision = request_record.revisions.last
      expect(revision).to be_valid
      create(:user, business: business, phone_number: "01001234599")
      expect(revision).not_to be_valid
      expect(revision.errors[:phone_number]).to be_present
    end
  end
end
