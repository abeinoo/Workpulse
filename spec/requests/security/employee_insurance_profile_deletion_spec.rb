require "rails_helper"

# SEC-P8-1 (found in Pilot 8 — Workforce Employee Insurance Profile, M0; High):
# Admin::EmployeeInsuranceProfilesController#set_profile fell back to
# @employee.build_employee_insurance_profile when the actor's policy scope did
# not return the employee's profile. User has_one :employee_insurance_profile,
# dependent: :destroy, so building through the association DELETED the existing
# profile — on a GET, before authorization refused the request, with no audit
# entry. Any same-business user past the admin gate could wipe another
# employee's insurance (payroll then treats them as uninsured).
#
# The fallback is now a standalone unsaved EmployeeInsuranceProfile, so a
# refused request writes nothing.
RSpec.describe "Security: insurance profile is not deleted by an unauthorized request", type: :request do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let!(:profile) do
    EmployeeInsuranceProfile.create!(user: employee, business: business, created_by: employee, insured: true,
                                     employee_contribution_amount: 10, employer_contribution_amount: 5,
                                     insurance_start_date: Date.new(2026, 1, 1), insurance_number: "INS-1")
  end

  def expect_refused
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  def expect_profile_untouched(before)
    expect(EmployeeInsuranceProfile.where(user: employee).pluck(:id)).to eq([ profile.id ])
    expect(profile.reload.attributes).to eq(before)
  end

  {
    "an admin-gate user without insurance permissions (view_attendance)" => [ [ :view_attendance ], {} ],
    "a view-only insurance user scoped to self" => [ %i[view_employees view_employee_insurance],
                                                    { "view_employees" => "self", "view_employee_insurance" => "self" } ]
  }.each do |who, (permissions, scopes)|
    it "GET edit by #{who} is refused and leaves the existing profile in place, unchanged" do
      before = profile.reload.attributes
      sign_in api_user_with(business, *permissions, scopes: scopes)

      get edit_admin_user_employee_insurance_profile_path(employee)

      expect_refused
      expect_profile_untouched(before)
    end
  end

  # Whether this actor may open the form at all is SEC-P8-2
  # (employee_insurance_profile_scope_spec.rb); here only that nothing is deleted.
  it "GET edit by a self-scoped insurance manager does not delete or change the existing profile" do
    before = profile.reload.attributes
    sign_in api_user_with(business, :view_employees, :view_employee_insurance, :manage_employee_insurance,
                          scopes: { "view_employees" => "self", "view_employee_insurance" => "self",
                                    "manage_employee_insurance" => "self" })

    get edit_admin_user_employee_insurance_profile_path(employee)

    expect_profile_untouched(before)
  end

  it "the owner still edits the existing profile (it is found, not rebuilt)" do
    sign_in create(:user, :owner, business: business)
    get edit_admin_user_employee_insurance_profile_path(employee)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("INS-1")
    expect(EmployeeInsuranceProfile.where(user: employee).pluck(:id)).to eq([ profile.id ])
  end

  it "an employee without a profile still gets a blank form for an authorized user, nothing saved" do
    newcomer = create(:user, business: business)
    sign_in create(:user, :owner, business: business)

    expect { get edit_admin_user_employee_insurance_profile_path(newcomer) }.not_to change(EmployeeInsuranceProfile, :count)
    expect(response).to have_http_status(:ok)
  end
end
