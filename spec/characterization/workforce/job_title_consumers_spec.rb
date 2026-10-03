require "rails_helper"

# Characterization (Department + JobTitle pilot, M1) — external callers of the
# JobTitle catalogue that are not covered elsewhere:
#   * onboarding approval (EmployeeDataRequests::Reviewer) creates the employee
#     through User, so User#job_title_from_catalog (D-WF1) applies to it;
#   * the JobTitle admin rename keeps the names employees already hold.
RSpec.describe "Characterization: JobTitle consumers" do
  describe "onboarding approval", type: :model do
    let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
    let(:manager)  { edr_manager(business: business) }
    let(:reviewer) { edr_reviewer(business: business) }
    let(:request) do
      create(:branch, business: business).tap { |b| b.update_column(:branch_manager_id, manager.id) }
      create(:employee_data_request, business: business, submitted_by: manager,
                                     national_id: "29501011234599", phone_number: "01001234599")
    end

    it "creates the employee with a title from the active catalogue" do
      result = EmployeeDataRequests::Reviewer.approve(request_id: request.id, actor: reviewer)
      expect(result).to be_ok
      expect(request.reload.employee.job_title).to eq("كوافير")
    end

    # The revision re-validates as the would-be User (EmployeeDataRequestRevision#
    # valid_as_employee mirrors User errors), so User#job_title_from_catalog
    # (D-WF1) refuses the approval before any save: ok: false, error: nil, and
    # the revision carries job_title :not_in_list.
    it "refuses approval when the requested title was deactivated after submission (User rule via the revision)" do
      request && reviewer # create both before measuring
      JobTitle.find_by!(business: business, name: "كوافير").update!(active: false)
      result = nil
      expect { result = EmployeeDataRequests::Reviewer.approve(request_id: request.id, actor: reviewer) }
        .not_to change(User, :count)
      expect(result).not_to be_ok
      expect(result.error).to be_nil
      expect(result.record).to be_a(EmployeeDataRequestRevision)
      expect(result.record.errors.details[:job_title]).to include(a_hash_including(error: :not_in_list))
      expect(request.reload).not_to be_approved
      expect(request.employee).to be_nil
    end
  end

  describe "admin rename", type: :request do
    let(:business) { create(:business) }

    it "changes the catalogue name only; employees keep the name they were saved with" do
      title    = create(:job_title, business: business, name: "Stylist")
      employee = create(:user, business: business, job_title: "Stylist")
      sign_in api_user_with(business, :view_employees, :manage_employees)
      patch admin_job_title_path(title), params: { job_title: { name: "Senior Stylist" } }
      expect(response).to redirect_to(admin_job_titles_path)
      expect(title.reload.name).to eq("Senior Stylist")
      expect(employee.reload.job_title).to eq("Stylist")
    end
  end
end
