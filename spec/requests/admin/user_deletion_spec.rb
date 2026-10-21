require "rails_helper"

# F-A5 — DELETE /admin/users/:id (Admin::UsersController#destroy →
# OrganizationAccess::DeleteUser): an employee with history is never deleted
# (refused with a message pointing to deactivation, nothing changes, no audit);
# an employee without history is deleted and the deletion is audited
# ("delete_employee"); every refusal is reported as a refusal, never as success.
RSpec.describe "Admin user deletion (F-A5)", type: :request do
  let(:business) { create(:business) }
  let(:admin)    { create(:user, :super_admin, business: business) }
  let(:employee) { create(:user, business: business, first_name: "Mona", last_name: "Saleh") }

  def delete_audits = AuditLog.where(action: "delete_employee")
  def refusal(reason) = I18n.t("flash.employee_delete_refused.#{reason}", name: employee.full_name)

  before { sign_in admin }

  describe "an employee with history" do
    UserHistoryBuilders::USER_HISTORY.each_key do |association|
      it "refuses while #{association} exist: the employee and the history stay, the refusal points to deactivation, no audit" do
        create_user_history(association, employee)
        before_count = user_history_count(association, employee)

        delete admin_user_path(employee)

        expect(response).to redirect_to(admin_users_path)
        expect(flash[:alert]).to eq(refusal(:has_history))
        expect(flash[:alert]).to include("Deactivate")
        expect(flash[:notice]).to be_nil
        expect(User.exists?(employee.id)).to be(true)
        expect(user_history_count(association, employee)).to eq(before_count)
        expect(delete_audits).to be_empty
      end
    end

    it "can still be deactivated (the existing action, unchanged)" do
      create_user_history(:payroll_entries, employee)

      patch toggle_active_admin_user_path(employee)

      expect(employee.reload.active).to be(false)
      expect(flash[:notice]).to eq(I18n.t("flash.user_deactivated", name: employee.full_name))
    end
  end

  describe "an employee without history" do
    it "is deleted with one delete_employee audit naming the actor and the employee" do
      employee_id = employee.id
      code        = employee.employee_code

      expect { delete admin_user_path(employee) }.to change(User, :count).by(-1)

      expect(response).to redirect_to(admin_users_path)
      expect(flash[:notice]).to eq(I18n.t("flash.employee_removed"))
      expect(flash[:alert]).to be_nil
      expect(delete_audits.count).to eq(1)
      expect(delete_audits.first).to have_attributes(actor_id: admin.id, business_id: business.id,
                                                     auditable_type: "User", auditable_id: employee_id)
      expect(delete_audits.first.metadata).to include("user_id" => employee_id, "full_name" => "Mona Saleh",
                                                      "email" => employee.email, "employee_code" => code)
    end
  end

  describe "other refusals" do
    it "a custody account: refused as a refusal (not a success), no audit" do
      create(:custody_account, business: business, user: employee)

      delete admin_user_path(employee)

      expect(flash[:alert]).to eq(refusal(:has_history))
      expect(flash[:notice]).to be_nil
      expect(User.exists?(employee.id)).to be(true)
      expect(delete_audits).to be_empty
    end

    it "a row of another table referencing the user (a foreign key): refused cleanly, no 500, nothing deleted" do
      AuditLog.create!(actor: employee, business: business, auditable: business, action: "update") # audit_logs.actor_id → users

      delete admin_user_path(employee)

      expect(response).to redirect_to(admin_users_path)
      expect(flash[:alert]).to eq(refusal(:linked_records))
      expect(User.exists?(employee.id)).to be(true)
      expect(delete_audits).to be_empty
    end

    it "an audit that cannot be written: the deletion is rolled back and reported as refused" do
      employee
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))

      delete admin_user_path(employee)

      expect(flash[:alert]).to eq(refusal(:audit_failed))
      expect(flash[:notice]).to be_nil
      expect(User.exists?(employee.id)).to be(true)
    end
  end

  describe "authorization (unchanged, checked before any deletion)" do
    it "refuses a user without manage_employees — even for an employee without history" do
      sign_in api_user_with(business, :view_employees)

      delete admin_user_path(employee)

      expect(response).to redirect_to(root_path)
      expect(User.exists?(employee.id)).to be(true)
      expect(delete_audits).to be_empty
    end

    it "still refuses deleting yourself" do
      delete admin_user_path(admin)

      expect(flash[:alert]).to eq(I18n.t("flash.cannot_delete_self"))
      expect(User.exists?(admin.id)).to be(true)
      expect(delete_audits).to be_empty
    end
  end
end
