require "rails_helper"

# Regression coverage: POST /shift_assignments (web) must only assign employees
# of the current user's business — same rule as the API fix S1
# (docs/api/baseline.md). The business always comes from current_user; a
# user_id or business_id from params is never trusted to cross it.
RSpec.describe "Web security — shift assignment creation business scope", type: :request do
  let(:business_a) { create(:business) }
  let(:business_b) { create(:business) }
  let(:branch_a)   { create(:branch, business: business_a) }
  let(:shift_a)    { create(:shift, :fixed_time, business: business_a) }

  let!(:owner_a)   { create(:user, :owner, business: business_a) }
  let(:manager_a)  { api_user_with(business_a, :view_shifts, :assign_shifts) }
  let(:employee_a) { create(:user, business: business_a) }
  let(:employee_b) { create(:user, business: business_b, first_name: "Foreignname") }

  let(:rejection) { I18n.t("activerecord.errors.models.shift_assignment.employee_not_in_business") }

  def create_assignment(user_id:, extra: {}, top_level: {})
    post shift_assignments_path, params: top_level.merge(
      shift_assignment: { user_id: user_id, shift_id: shift_a.id, branch_id: branch_a.id,
                          effective_from: Date.current.to_s }.merge(extra)
    )
  end

  describe "1. same-business employee" do
    it "is assigned by the owner" do
      sign_in owner_a
      expect { create_assignment(user_id: employee_a.id) }.to change(ShiftAssignment, :count).by(1)
      expect(response).to redirect_to(shift_assignments_path)

      assignment = ShiftAssignment.order(:id).last
      expect(assignment).to have_attributes(user_id: employee_a.id, shift_id: shift_a.id,
                                            branch_id: branch_a.id, created_by_id: owner_a.id)
    end

    it "is assigned by a manager holding assign_shifts" do
      sign_in manager_a
      expect { create_assignment(user_id: employee_a.id) }.to change(ShiftAssignment, :count).by(1)
      expect(response).to redirect_to(shift_assignments_path)
    end
  end

  describe "2. cross-business employee" do
    it "is rejected with the form re-rendered (422) and nothing created" do
      sign_in owner_a
      expect { create_assignment(user_id: employee_b.id) }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(rejection)
    end

    it "does not reveal the foreign employee in the re-rendered form" do
      sign_in owner_a
      create_assignment(user_id: employee_b.id)
      expect(response.body).not_to include("Foreignname")
    end

    it "is rejected for a manager as well" do
      sign_in manager_a
      expect { create_assignment(user_id: employee_b.id) }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "is rejected in the other direction (Business B owner → Business A employee)" do
      owner_b = create(:user, :owner, business: business_b)
      shift_b = create(:shift, :fixed_time, business: business_b)
      branch_b = create(:branch, business: business_b)
      sign_in owner_b
      expect {
        post shift_assignments_path, params: {
          shift_assignment: { user_id: employee_a.id, shift_id: shift_b.id, branch_id: branch_b.id,
                              effective_from: Date.current.to_s }
        }
      }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "3. business_id manipulation" do
    before { sign_in owner_a }

    it "cannot bypass the check via shift_assignment[business_id]" do
      expect { create_assignment(user_id: employee_b.id, extra: { business_id: business_b.id }) }
        .not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "cannot bypass the check via a top-level business_id" do
      expect { create_assignment(user_id: employee_b.id, top_level: { business_id: business_b.id }) }
        .not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "4. non-existent employee" do
    it "is rejected safely with the same message as a foreign employee" do
      sign_in owner_a
      expect { create_assignment(user_id: 0) }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(rejection)
    end

    it "a blank employee still fails the model's own validation (unchanged)" do
      sign_in owner_a
      expect { create_assignment(user_id: "") }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include(rejection)
    end
  end

  describe "5. existing behaviour is unchanged" do
    it "still rejects an overlapping assignment for a same-business employee" do
      create(:shift_assignment, user: employee_a, shift: shift_a, branch: branch_a, effective_from: 1.month.ago.to_date)
      sign_in owner_a
      expect { create_assignment(user_id: employee_a.id) }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include(rejection)
    end

    it "still denies a user without assign_shifts (Pundit redirect), even for a foreign employee" do
      sign_in employee_a
      expect { create_assignment(user_id: employee_b.id) }.not_to change(ShiftAssignment, :count)
      expect(response).to redirect_to(root_path)
    end

    it "still requires sign-in" do
      expect { create_assignment(user_id: employee_a.id) }.not_to change(ShiftAssignment, :count)
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
