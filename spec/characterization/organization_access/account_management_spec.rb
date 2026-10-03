require "rails_helper"

# Characterization — account self-service and administrative account management
# (CURRENT behaviour). Security boundaries are covered by
# spec/requests/security/organization_access_*_spec.rb and not repeated here.
RSpec.describe "Characterization: Organization & Access accounts", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:hr)       { api_user_with(business, :view_employees, :manage_employees, scopes: { "manage_employees" => "business" }) }
  let(:employee) { create(:user, business: business) }

  describe "self password change (/profile/password)" do
    it "requires the current password, keeps the session and records a password_changed_self audit entry" do
      sign_in employee
      expect {
        patch profile_password_path, params: { user: { current_password: "password123",
                                                       password: "newsecret123", password_confirmation: "newsecret123" } }
      }.to change(UserAuditLog, :count).by(1)

      expect(response).to redirect_to(root_path)
      expect(employee.reload.valid_password?("newsecret123")).to be(true)
      expect(UserAuditLog.last).to have_attributes(actor_id: employee.id, target_user_id: employee.id,
                                                   action: "password_changed_self")
      get root_path
      expect(response).to have_http_status(:ok) # still signed in (bypass_sign_in)
    end

    it "refuses a wrong current password and writes no audit entry" do
      sign_in employee
      expect {
        patch profile_password_path, params: { user: { current_password: "wrong",
                                                       password: "newsecret123", password_confirmation: "newsecret123" } }
      }.not_to change(UserAuditLog, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(employee.reload.valid_password?("password123")).to be(true)
    end

    it "requires sign-in" do
      patch profile_password_path, params: { user: { password: "x" } }
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "administrative password reset (/admin/users/:id/password)" do
    it "records a password_reset_by_admin audit entry with actor, target and IP" do
      sign_in hr
      expect {
        patch admin_user_password_path(employee), params: { user: { password: "resetpass123", password_confirmation: "resetpass123" } }
      }.to change(UserAuditLog, :count).by(1)

      expect(response).to redirect_to(admin_user_path(employee))
      expect(UserAuditLog.last).to have_attributes(actor_id: hr.id, target_user_id: employee.id,
                                                   action: "password_reset_by_admin")
      expect(UserAuditLog.last.ip_address).to be_present
    end

    it "re-renders on a confirmation mismatch without changing the password or auditing" do
      sign_in hr
      expect {
        patch admin_user_password_path(employee), params: { user: { password: "resetpass123", password_confirmation: "nope" } }
      }.not_to change(UserAuditLog, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "account status" do
    it "toggle_active flips the account status and is NOT audited (existing behaviour)" do
      sign_in hr
      expect { patch toggle_active_admin_user_path(employee) }.not_to change { [ UserAuditLog.count, AuditLog.count ] }
      expect(employee.reload.active).to be(false)
      expect(flash[:notice]).to eq(I18n.t("flash.user_deactivated", name: employee.full_name))
    end
  end

  describe "ownership transfer" do
    it "is available only to the owner and moves Business#owner" do
      sign_in owner
      patch transfer_ownership_admin_user_path(employee)
      expect(response).to redirect_to(admin_user_path(employee))
      expect(business.reload.owner_id).to eq(employee.id)
    end

    it "is refused for a non-owner" do
      sign_in hr
      patch transfer_ownership_admin_user_path(employee)
      expect(response).to redirect_to(root_path)
      expect(business.reload.owner_id).to eq(owner.id)
    end
  end

  describe "employee creation by an administrator" do
    it "creates a pending-registration account (no password) in the actor's business with a generated code" do
      sign_in owner
      post admin_users_path, params: { user: { first_name: "New", last_name: "Hire", email: "newhire@example.com",
                                               identity_card_number: "ID-CHAR-0001", business_id: create(:business).id } }
      created = User.find_by!(email: "newhire@example.com")
      expect(created.business_id).to eq(business.id)
      expect(created.encrypted_password).to be_blank
      expect(created.employee_code).to be_present
      expect(created.permission_role).to be_nil
    end
  end

  describe "deletion" do
    it "deletes an employee without restricting history" do
      sign_in owner
      delete admin_user_path(employee)
      expect(User.exists?(employee.id)).to be(false)
    end

    # KNOWN DEFECT (existing behaviour): Admin::UsersController#destroy ignores
    # the result of destroy. A user with a custody account (restrict_with_error)
    # is NOT deleted, yet the success notice is shown.
    it "reports success even when deletion is blocked by restricted history (known defect)" do
      create(:custody_account, business: business, user: employee)
      sign_in owner
      delete admin_user_path(employee)
      expect(User.exists?(employee.id)).to be(true)
      expect(flash[:notice]).to eq(I18n.t("flash.employee_removed"))
    end
  end
end
