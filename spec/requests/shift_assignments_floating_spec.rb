require "rails_helper"

# Creating a floating assignment from the web form: business-wide assigners
# only, through the same availability gate as a regular assignment, never with
# a branch.
RSpec.describe "ShiftAssignments — floating", type: :request do
  let(:business) { create(:business, timezone: "UTC") }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:employee) { create(:user, business: business) }

  def create_floating(branch_id: nil)
    post shift_assignments_path, params: { shift_assignment: {
      user_id: employee.id, shift_id: shift.id, branch_id: branch_id,
      effective_from: Date.current, assignment_kind: "floating"
    } }
  end

  context "as a business-wide assigner" do
    before { sign_in owner }

    it "offers the floating kind on the form" do
      get new_shift_assignment_path

      expect(response.body).to include('value="floating"')
      expect(response.body).to include(I18n.t("shift_assignments.form.floating_hint"))
    end

    it "creates a floating assignment with no branch" do
      expect { create_floating }.to change(ShiftAssignment.floating, :count).by(1)

      expect(response).to redirect_to(shift_assignments_path)
      expect(ShiftAssignment.floating.last).to have_attributes(user_id: employee.id, branch_id: nil)
    end

    it "refuses a floating assignment carrying a branch" do
      expect { create_floating(branch_id: create(:branch, business: business).id) }.not_to change(ShiftAssignment, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses an employee who still has an open regular assignment" do
      create(:shift_assignment, user: employee, shift: shift, branch: create(:branch, business: business))

      expect { create_floating }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "lists the floating assignment as Floating, in English and Arabic" do
      create(:shift_assignment, :floating, user: employee, shift: shift)

      get shift_assignments_path, params: { tab: "all" }
      expect(response.body).to include(I18n.t("shift_assignments.floating.label", locale: :en))

      owner.update!(preferred_locale: "ar")
      get shift_assignments_path, params: { tab: "all" }
      expect(response.body).to include(I18n.t("shift_assignments.floating.label", locale: :ar))
    end
  end

  context "as a branch manager" do
    let(:manager) { create(:user, :branch_manager, business: business) }

    before { sign_in manager }

    it "does not offer the floating kind" do
      get new_shift_assignment_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('value="floating"')
    end

    it "cannot create a floating assignment" do
      expect { create_floating }.not_to change(ShiftAssignment, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML(I18n.t("activerecord.errors.models.shift_assignment.floating_not_allowed")))
    end
  end
end
