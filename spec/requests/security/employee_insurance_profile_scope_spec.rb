require "rails_helper"

# SEC-P8-2 (found in Pilot 8 — Workforce Employee Insurance Profile, M0;
# Medium): EmployeeInsuranceProfilePolicy#create?/#update? checked only the
# manage_employee_insurance flag, and the controller found the employee
# business-wide, so a holder scoped to self or branch could create or change
# the insurance of ANY employee in the business — although
# EmployeeInsuranceProfilePolicy::Scope already limited what they could see.
#
# create?/update? now require the employee to be inside that same insurance
# scope (manage_employee_insurance, else view_employee_insurance, else the
# manager hierarchy; one's own profile included, as in the Scope). Out of
# scope → the usual not-authorized redirect, nothing written.
RSpec.describe "Security: employee insurance scope on create / update", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }

  let!(:employee_a) { create(:user, business: business) }
  let!(:employee_b) { create(:user, business: business) }

  let(:insurance_permissions) { %i[view_employees view_employee_insurance manage_employee_insurance] }

  def scoped(scope)
    { "view_employees" => scope, "view_employee_insurance" => scope, "manage_employee_insurance" => scope }
  end

  let(:self_manager)   { api_user_with(business, *insurance_permissions, scopes: scoped("self")) }
  let(:branch_manager) { api_user_with(business, *insurance_permissions, scopes: scoped("branch")) }

  before do
    branch_a.update_column(:branch_manager_id, branch_manager.id)
    create(:shift_assignment, business: business, user: employee_a, branch: branch_a)
    create(:shift_assignment, business: business, user: employee_b, branch: branch_b)
  end

  def profile_for(user, amount = 10)
    EmployeeInsuranceProfile.create!(user: user, business: user.business, created_by: user, insured: true,
                                     employee_contribution_amount: amount, employer_contribution_amount: 5,
                                     insurance_start_date: Date.new(2026, 1, 1))
  end

  def submit(user, amount)
    patch admin_user_employee_insurance_profile_path(user),
          params: { employee_insurance_profile: { insured: "1", employee_contribution_amount: amount,
                                                  employer_contribution_amount: 1, insurance_start_date: "2026-02-01" } }
  end

  def expect_refused
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "out of scope: refused, nothing written" do
    it "a self-scoped manager cannot update another employee's profile (nor open its form)" do
      profile = profile_for(employee_a)
      before  = profile.reload.attributes
      sign_in self_manager

      get edit_admin_user_employee_insurance_profile_path(employee_a)
      expect_refused

      submit(employee_a, 777)
      expect_refused
      expect(profile.reload.attributes).to eq(before)
    end

    it "a branch-scoped manager cannot update an employee outside their branch" do
      profile = profile_for(employee_b)
      before  = profile.reload.attributes
      sign_in branch_manager

      submit(employee_b, 777)

      expect_refused
      expect(profile.reload.attributes).to eq(before)
    end

    it "a branch-scoped manager cannot create a profile for an employee outside their branch" do
      sign_in branch_manager

      expect { submit(employee_b, 333) }.not_to change(EmployeeInsuranceProfile, :count)
      expect_refused
      expect(employee_b.reload.employee_insurance_profile).to be_nil
    end

    it "a self-scoped manager cannot create a profile for another employee" do
      sign_in self_manager

      expect { submit(employee_a, 333) }.not_to change(EmployeeInsuranceProfile, :count)
      expect_refused
    end

    it "with no scope configured, the manager hierarchy applies: an unmanaged employee is refused" do
      sign_in api_user_with(business, *insurance_permissions)

      expect { submit(employee_b, 333) }.not_to change(EmployeeInsuranceProfile, :count)
      expect_refused
    end
  end

  describe "in scope: unchanged" do
    it "a branch-scoped manager updates an employee in their branch" do
      profile = profile_for(employee_a)
      sign_in branch_manager

      get edit_admin_user_employee_insurance_profile_path(employee_a)
      expect(response).to have_http_status(:ok)

      submit(employee_a, 777)
      expect(response).to redirect_to(admin_user_path(employee_a))
      expect(profile.reload.employee_contribution_amount).to eq(777)
    end

    it "a branch-scoped manager creates a profile for an employee in their branch" do
      sign_in branch_manager

      expect { submit(employee_a, 333) }.to change(EmployeeInsuranceProfile, :count).by(1)
      expect(employee_a.reload.employee_insurance_profile.employee_contribution_amount).to eq(333)
    end

    it "a self-scoped manager updates their own profile" do
      profile = profile_for(self_manager)
      sign_in self_manager

      submit(self_manager, 444)
      expect(response).to redirect_to(admin_user_path(self_manager))
      expect(profile.reload.employee_contribution_amount).to eq(444)
    end

    it "a business-scoped manager and the owner update anyone in the business" do
      sign_in api_user_with(business, *insurance_permissions, scopes: scoped("business"))
      submit(employee_b, 555)
      expect(employee_b.reload.employee_insurance_profile.employee_contribution_amount).to eq(555)

      sign_in create(:user, :owner, business: business)
      submit(employee_b, 556)
      expect(employee_b.reload.employee_insurance_profile.employee_contribution_amount).to eq(556)
    end
  end

  describe "cross-business: still rejected" do
    it "a business-scoped manager gets 404 for another business's employee, nothing created" do
      foreign = create(:user, business: other)
      sign_in api_user_with(business, *insurance_permissions, scopes: scoped("business"))

      expect { submit(foreign, 999) }.not_to change(EmployeeInsuranceProfile, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
