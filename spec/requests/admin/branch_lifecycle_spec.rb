require "rails_helper"

# BUG-026 — branch lifecycle through the admin UI: deactivate / reactivate /
# delete report what actually happened, refusals are explained, the edit form
# can no longer flip `active` around the safeguards, inactive branches keep
# their history visible but take no new shift assignments.
RSpec.describe "Admin branch lifecycle (BUG-026)", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business, name: "Retiring", active: true) }
  let!(:main_branch) { create(:branch, business: business, name: "Main", active: true) }
  let(:employee) { create(:user, business: business) }

  def audits_for(record, action) = AuditLog.where(auditable_type: "Branch", auditable_id: record.id, action: action)

  describe "PATCH deactivate" do
    before { sign_in owner }

    it "deactivates with a reason and says so" do
      patch deactivate_admin_branch_path(branch), params: { reason: "Closed" }

      expect(response).to redirect_to(admin_branch_path(branch))
      expect(flash[:notice]).to eq(I18n.t("flash.branch_deactivated"))
      expect(branch.reload).not_to be_active
      expect(audits_for(branch, "deactivate").count).to eq(1)
    end

    it "refuses without a reason and says why" do
      patch deactivate_admin_branch_path(branch), params: { reason: "" }

      expect(response).to redirect_to(admin_branch_path(branch))
      expect(flash[:alert]).to eq(I18n.t("admin.branches.lifecycle.errors.reason_required"))
      expect(flash[:notice]).to be_nil
      expect(branch.reload).to be_active
    end

    context "with staff assignments at the branch" do
      let(:business_day) { BusinessDay.current(context: business) }
      let(:shift)        { create(:shift, :fixed_time, business: business) }

      it "refuses while an assignment is still in effect and explains what to do" do
        assignment = create(:shift_assignment, user: employee, shift: shift, branch: branch,
                                               effective_from: business_day - 10)

        patch deactivate_admin_branch_path(branch), params: { reason: "Closed" }

        expect(response).to redirect_to(admin_branch_path(branch))
        expect(flash[:alert]).to eq(I18n.t("admin.branches.lifecycle.errors.active_assignments"))
        expect(flash[:notice]).to be_nil
        expect(branch.reload).to be_active
        expect(assignment.reload).to have_attributes(branch_id: branch.id, effective_to: nil)
        expect(audits_for(branch, "deactivate")).to be_empty
      end

      it "deactivates when only ended assignments remain, keeping them" do
        assignment = create(:shift_assignment, user: employee, shift: shift, branch: branch,
                                               effective_from: business_day - 40, effective_to: business_day - 1)

        patch deactivate_admin_branch_path(branch), params: { reason: "Closed" }

        expect(flash[:notice]).to eq(I18n.t("flash.branch_deactivated"))
        expect(branch.reload).not_to be_active
        expect(assignment.reload.branch_id).to eq(branch.id)
      end
    end

    it "refuses the last active branch without a success message or audit entry" do
      main_branch.update_column(:active, false)

      patch deactivate_admin_branch_path(branch), params: { reason: "Closed" }

      expect(flash[:alert]).to eq(I18n.t("admin.branches.lifecycle.errors.last_active_branch"))
      expect(flash[:notice]).to be_nil
      expect(branch.reload).to be_active
      expect(audits_for(branch, "deactivate")).to be_empty
    end
  end

  # BUG-029 — what Laundry still records at the branch, shown in the dialog
  # through OrganizationAccess::BranchDeactivationNotices, never enforced.
  describe "the deactivation towel warning" do
    let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

    def notice = Nokogiri::HTML(response.body).at_css("[data-testid='branch-deactivate-notice']")

    before do
      Laundry::TowelAdjuster.new(actor: owner).call(towel_type: towel_type, branch: branch, status: "clean",
                                                    adjustment_quantity: 12, reason: "setup")
      sign_in owner
    end

    it "shows the recorded balances in the deactivation dialog, labelled as information only" do
      get admin_branch_path(branch)

      expect(response).to have_http_status(:ok)
      expect(notice).to be_present
      expect(notice.text).to include(I18n.t("laundry.deactivation_notice.title"),
                                     I18n.t("laundry.deactivation_notice.summary"),
                                     I18n.t("admin.branches.lifecycle.notice_not_blocking"),
                                     "Bath Towel", "12")
    end

    it "shows no warning for a branch with nothing recorded" do
      get admin_branch_path(main_branch)

      expect(response).to have_http_status(:ok)
      expect(notice).to be_nil
    end

    it "does not prevent deactivation, and leaves the balance untouched" do
      patch deactivate_admin_branch_path(branch), params: { reason: "Closed" }

      expect(flash[:notice]).to eq(I18n.t("flash.branch_deactivated"))
      expect(branch.reload).not_to be_active
      expect(Laundry::TowelBalances.new(towel_type).at_branch(branch, "clean")).to eq(12)
    end
  end

  describe "PATCH reactivate" do
    before do
      branch.update_column(:active, false)
      sign_in owner
    end

    it "reactivates and says so" do
      patch reactivate_admin_branch_path(branch)

      expect(response).to redirect_to(admin_branch_path(branch))
      expect(flash[:notice]).to eq(I18n.t("flash.branch_reactivated"))
      expect(branch.reload).to be_active
      expect(audits_for(branch, "reactivate").count).to eq(1)
    end
  end

  describe "DELETE destroy" do
    before { sign_in owner }

    it "permanently deletes a never-used branch and says so" do
      delete admin_branch_path(branch), params: { reason: "Created by mistake" }

      expect(response).to redirect_to(admin_branches_path)
      expect(flash[:notice]).to eq(I18n.t("flash.branch_deleted"))
      expect(Branch.exists?(branch.id)).to be(false)
      expect(audits_for(branch, "destroy").count).to eq(1)
    end

    it "refuses a branch with history, keeps it, and points to deactivation" do
      record = create(:attendance_record, :checked_out, business: business, user: employee, branch: branch)
      punch  = create(:biometric_punch_log, business: business, employee: employee, attendance_record: record)

      delete admin_branch_path(branch), params: { reason: "Closing" }

      expect(response).to redirect_to(admin_branch_path(branch))
      expect(flash[:alert]).to eq(I18n.t("admin.branches.lifecycle.errors.has_history"))
      expect(flash[:notice]).to be_nil
      expect(Branch.exists?(branch.id)).to be(true)
      expect(AttendanceRecord.exists?(record.id)).to be(true)
      expect(BiometricPunchLog.exists?(punch.id)).to be(true)
      expect(audits_for(branch, "destroy")).to be_empty
    end

    it "refuses a branch referenced only by a database foreign key without an error page" do
      DailyReconciliation.create_for!(branch: branch)

      delete admin_branch_path(branch), params: { reason: "Closing" }

      expect(response).to redirect_to(admin_branch_path(branch))
      expect(flash[:alert]).to eq(I18n.t("admin.branches.lifecycle.errors.has_history"))
      expect(Branch.exists?(branch.id)).to be(true)
    end

    it "refuses without a reason" do
      delete admin_branch_path(branch), params: { reason: " " }

      expect(flash[:alert]).to eq(I18n.t("admin.branches.lifecycle.errors.reason_required"))
      expect(Branch.exists?(branch.id)).to be(true)
    end
  end

  describe "the edit form" do
    before { sign_in owner }

    it "can no longer change active around the lifecycle safeguards" do
      patch admin_branch_path(branch), params: { branch: { name: "Renamed", active: "0" } }

      expect(branch.reload).to have_attributes(name: "Renamed", active: true)
      expect(audits_for(branch, "deactivate")).to be_empty
    end
  end

  describe "authorization and business boundaries" do
    it "refuses every lifecycle action to a user without manage_branches" do
      clerk = api_user_with(business, :view_employees)
      sign_in clerk

      patch deactivate_admin_branch_path(branch), params: { reason: "x" }
      delete admin_branch_path(branch), params: { reason: "x" }

      expect(branch.reload).to be_active
      expect(Branch.exists?(branch.id)).to be(true)
      expect(AuditLog.where(auditable_type: "Branch")).to be_empty
    end

    it "cannot touch another business's branch" do
      foreign = create(:branch, business: create(:business))

      # Signed in before each request: a 404 response does not write the
      # session cookie back in request specs.
      sign_in owner
      patch deactivate_admin_branch_path(foreign), params: { reason: "x" }
      expect(response).to have_http_status(:not_found)

      sign_in owner
      delete admin_branch_path(foreign), params: { reason: "x" }
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload).to be_active
    end
  end

  describe "an inactive branch" do
    let(:shift) { create(:shift, :fixed_time, business: business) }

    before { branch.update_column(:active, false) }

    it "keeps its page and history reachable" do
      # History recorded while the branch was still active.
      branch.update_column(:active, true)
      record = create(:attendance_record, :checked_out, business: business, user: employee, branch: branch)
      branch.update_column(:active, false)
      sign_in owner

      get admin_branch_path(branch)

      expect(response).to have_http_status(:ok)
      expect(AttendanceRecord.find(record.id).branch_id).to eq(branch.id)
    end

    it "takes no new shift assignment from the web" do
      sign_in owner

      expect {
        post shift_assignments_path, params: { shift_assignment: {
          user_id: employee.id, shift_id: shift.id, branch_id: branch.id, effective_from: Date.current.to_s
        } }
      }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "takes no new shift assignment from the API" do
      sign_in api_user_with(business, :view_shifts, :assign_shifts)

      expect {
        post "/api/v1/shift_assignments",
             params: { shift_assignment: { user_id: employee.id, shift_id: shift.id, branch_id: branch.id,
                                           effective_from: Date.current } },
             as: :json
      }.not_to change(ShiftAssignment, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "still lets an existing assignment there be ended" do
      assignment = create(:shift_assignment, user: employee, shift: shift, branch: main_branch,
                                             effective_from: 1.month.ago.to_date)
      assignment.update_column(:branch_id, branch.id)

      assignment.update!(effective_to: Date.current)

      expect(assignment.reload).to have_attributes(branch_id: branch.id, effective_to: Date.current)
    end

    describe "an ended assignment there" do
      let(:business_day) { BusinessDay.current(context: business) }
      let(:ended_on)     { business_day - 10 }
      let!(:assignment) do
        branch.update_column(:active, true)
        create(:shift_assignment, user: employee, shift: shift, branch: branch,
                                  effective_from: business_day - 60, effective_to: ended_on)
          .tap { branch.update_column(:active, false) }
      end

      it "cannot be reopened from the web edit form" do
        sign_in owner

        patch shift_assignment_path(assignment), params: { shift_assignment: { effective_to: "" } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(assignment.reload.effective_to).to eq(ended_on)
      end

      it "cannot be extended into effect through the API" do
        sign_in owner

        patch "/api/v1/shift_assignments/#{assignment.id}",
              params: { shift_assignment: { effective_to: business_day + 30 } }, as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"])
          .to include(I18n.t("activerecord.errors.models.shift_assignment.branch_inactive_reopen"))
        expect(assignment.reload.effective_to).to eq(ended_on)
      end
    end
  end
end
