require "rails_helper"

RSpec.describe "Admin::ShiftTemplates", type: :request do
  let(:business)    { create(:business) }
  let(:owner)       { create(:user, :super_admin, business: business) }
  let(:employee)    { create(:user, business: business) }

  let(:shift)       { create(:shift, :fixed_time, business: business) }
  let!(:template)   { create(:shift_template, business: business, created_by: owner) }

  # ── Index ──────────────────────────────────────────────────────────────────

  describe "GET /admin/shift_templates" do
    context "as owner" do
      before { sign_in owner }

      it "returns 200" do
        get admin_shift_templates_path
        expect(response).to have_http_status(:ok)
      end

      it "shows active templates by default" do
        get admin_shift_templates_path
        expect(response.body).to include(template.name)
      end

      it "shows archived tab" do
        archived = create(:shift_template, :archived, business: business, created_by: owner)
        get admin_shift_templates_path(tab: "archived")
        expect(response.body).to include(archived.name)
        expect(response.body).not_to include(template.name)
      end
    end

    context "as employee" do
      before { sign_in employee }

      it "redirects (access denied)" do
        get admin_shift_templates_path
        expect(response).to redirect_to(root_path)
      end
    end

    context "not signed in" do
      it "redirects to sign in" do
        get admin_shift_templates_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ── Show ───────────────────────────────────────────────────────────────────

  describe "GET /admin/shift_templates/:id" do
    before { sign_in owner }

    it "returns 200" do
      get admin_shift_template_path(template)
      expect(response).to have_http_status(:ok)
    end

    it "shows the template name" do
      get admin_shift_template_path(template)
      expect(response.body).to include(template.name)
    end
  end

  # ── Create ─────────────────────────────────────────────────────────────────

  describe "POST /admin/shift_templates" do
    before { sign_in owner }

    let(:valid_params) do
      {
        shift_template: {
          name:        "Ramadan Schedule",
          description: "Shorter hours during Ramadan",
          active:      true,
          entries_attributes: {
            "0" => {
              starts_on:  Date.current.to_s,
              ends_on:    (Date.current + 6.days).to_s,
              shift_id:   shift.id
            }
          }
        }
      }
    end

    it "creates a template and redirects to show" do
      expect {
        post admin_shift_templates_path, params: valid_params
      }.to change(ShiftTemplate, :count).by(1)
      expect(response).to redirect_to(admin_shift_template_path(ShiftTemplate.last))
    end

    it "creates entries along with the template" do
      expect {
        post admin_shift_templates_path, params: valid_params
      }.to change(ShiftTemplateEntry, :count).by(1)
    end

    it "renders new with errors on invalid params" do
      post admin_shift_templates_path, params: { shift_template: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ── Update ─────────────────────────────────────────────────────────────────

  describe "PATCH /admin/shift_templates/:id" do
    before { sign_in owner }

    it "updates the template and redirects to show" do
      patch admin_shift_template_path(template),
            params: { shift_template: { name: "Updated Name", description: "" } }
      expect(response).to redirect_to(admin_shift_template_path(template))
      expect(template.reload.name).to eq("Updated Name")
    end

    it "renders edit with errors on invalid params" do
      patch admin_shift_template_path(template),
            params: { shift_template: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ── Archive / Unarchive ────────────────────────────────────────────────────

  describe "PATCH /admin/shift_templates/:id/archive" do
    before { sign_in owner }

    it "archives the template and redirects to index" do
      patch archive_admin_shift_template_path(template)
      expect(response).to redirect_to(admin_shift_templates_path)
      expect(template.reload.archived?).to be true
    end
  end

  describe "PATCH /admin/shift_templates/:id/unarchive" do
    let!(:archived) { create(:shift_template, :archived, business: business, created_by: owner) }

    before { sign_in owner }

    it "unarchives the template and redirects to archived tab" do
      patch unarchive_admin_shift_template_path(archived)
      expect(response).to redirect_to(admin_shift_templates_path(tab: "archived"))
      expect(archived.reload.archived?).to be false
    end
  end

  # ── Apply flow ─────────────────────────────────────────────────────────────

  describe "GET /admin/shift_templates/:id/apply" do
    let!(:branch) { create(:branch, business: business, name: "Downtown") }

    before { sign_in owner }

    it "returns 200 and offers the branch selector" do
      get apply_admin_shift_template_path(template)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(name="branch_id"), "Downtown")
    end
  end

  # The branch is chosen once when applying (entries carry no branch) and must be
  # one the actor may assign shifts to; it is resolved before anything is written.
  describe "applying with a selected branch" do
    let(:emp)          { create(:user, business: business) }
    let(:branch)       { create(:branch, business: business) }
    let(:other_branch) { create(:branch, business: business) }
    let(:foreign)      { create(:branch, business: create(:business)) }

    before do
      create(:shift_template_entry,
             shift_template: template,
             shift:          shift,
             branch:         nil,
             starts_on:      Date.current,
             ends_on:        Date.current + 30.days)
    end

    def preview(branch_id, employee_ids: [ emp.id ])
      post preview_apply_admin_shift_template_path(template), params: { employee_ids: employee_ids, branch_id: branch_id }
    end

    def confirm(branch_id, employee_ids: [ emp.id ])
      post apply_confirm_admin_shift_template_path(template), params: { employee_ids: employee_ids, branch_id: branch_id }
    end

    context "as the owner (business-wide)" do
      before { sign_in owner }

      it "previews against the selected branch and carries it to the confirm form" do
        preview(branch.id)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(name="branch_id"), %(value="#{branch.id}"), branch.name)
      end

      it "re-renders apply with error when no employees selected" do
        preview(branch.id, employee_ids: [])
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "creates the assignments at the selected branch and redirects to the template" do
        expect { confirm(branch.id) }.to change(ShiftAssignment, :count).by(1)
        expect(ShiftAssignment.last).to have_attributes(user_id: emp.id, branch_id: branch.id, source_template_id: template.id)
        expect(response).to redirect_to(admin_shift_template_path(template))
      end

      it "redirects with alert when no employees selected" do
        confirm(branch.id, employee_ids: [])
        expect(response).to redirect_to(apply_admin_shift_template_path(template))
      end

      it "refuses a missing branch in preview and confirm, writing nothing" do
        preview(nil)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include(CGI.escapeHTML(I18n.t("shift_templates.apply.branch_required")))

        expect { confirm(nil) }.not_to change(ShiftAssignment, :count)
        expect(response).to redirect_to(apply_admin_shift_template_path(template))
        expect(flash[:alert]).to eq(I18n.t("shift_templates.apply.branch_required"))
      end

      it "refuses another business's branch, writing nothing" do
        preview(foreign.id)
        expect(response).to have_http_status(:unprocessable_entity)

        expect { confirm(foreign.id) }.not_to change(ShiftAssignment, :count)
        expect(flash[:alert]).to eq(I18n.t("shift_templates.apply.branch_not_allowed"))
      end

      it "refuses an inactive branch, writing nothing" do
        branch.update!(active: false)
        expect { confirm(branch.id) }.not_to change(ShiftAssignment, :count)
        expect(flash[:alert]).to eq(I18n.t("shift_templates.apply.branch_not_allowed"))
      end

      it "skips an employee who already holds an overlapping assignment at the selected branch" do
        create(:shift_assignment, user: emp, branch: branch, shift: shift,
               effective_from: Date.current - 10.days, effective_to: nil)
        expect { confirm(branch.id) }.not_to change(ShiftAssignment, :count)
      end

      it "warns in the preview when the employee has no history at the selected branch" do
        preview(branch.id)
        expect(response.body).to include(CGI.escapeHTML(I18n.t("shift_templates.conflicts.branch_mismatch")))
      end
    end

    # A branch-scoped manager reaches only the employees the Assign Shift form
    # offers them (EmployeeScope for assign_shifts / view_shifts / view_employees):
    # here, the current members of the branch they manage.
    context "as a branch-scoped manager" do
      let(:manager) do
        role = create(:permission_role, business: business, permissions: %w[view_shifts assign_shifts view_employees])
        create(:user, business: business, permission_role: role)
      end
      let(:outsider) { create(:user, business: business, first_name: "Outside", last_name: "Scope") }

      before do
        branch.update_column(:branch_manager_id, manager.id)
        # emp is a current member of the managed branch; outsider of another one.
        # Both current assignments end before the template's window, so the
        # template rows themselves do not overlap them.
        create(:shift_assignment, user: emp, branch: branch, shift: shift,
               effective_from: Date.current - 30.days, effective_to: Date.current + 30.days)
        create(:shift_assignment, user: outsider, branch: other_branch, shift: shift,
               effective_from: Date.current - 30.days, effective_to: Date.current + 30.days)
        template.entries.update_all(starts_on: Date.current + 40.days, ends_on: Date.current + 70.days)
        sign_in manager
      end

      it "is offered only the employees in their scope" do
        get apply_admin_shift_template_path(template)
        expect(response.body).to include(%(value="#{emp.id}"))
        expect(response.body).not_to include(%(value="#{outsider.id}"))
      end

      it "applies the template to an employee in their scope at a branch they manage" do
        expect { confirm(branch.id) }.to change(ShiftAssignment, :count).by(1)
        expect(ShiftAssignment.last).to have_attributes(user_id: emp.id, branch_id: branch.id)
      end

      it "is refused an employee outside their scope, writing nothing" do
        preview(branch.id, employee_ids: [ outsider.id ])
        expect(response).to have_http_status(:unprocessable_entity)

        expect { confirm(branch.id, employee_ids: [ outsider.id ]) }.not_to change(ShiftAssignment, :count)
        expect(flash[:alert]).to eq(I18n.t("shift_templates.apply.employees_not_allowed"))
      end

      it "refuses a mixed selection outright — no partial assignments for the in-scope employee" do
        preview(branch.id, employee_ids: [ emp.id, outsider.id ])
        expect(response).to have_http_status(:unprocessable_entity)

        expect { confirm(branch.id, employee_ids: [ emp.id, outsider.id ]) }.not_to change(ShiftAssignment, :count)
        expect(flash[:alert]).to eq(I18n.t("shift_templates.apply.employees_not_allowed"))
      end

      it "refuses an employee from another business, writing nothing" do
        foreign_user = create(:user, business: create(:business))
        expect { confirm(branch.id, employee_ids: [ emp.id, foreign_user.id ]) }.not_to change(ShiftAssignment, :count)
        expect(flash[:alert]).to eq(I18n.t("shift_templates.apply.employees_not_allowed"))
      end

      it "is refused a branch outside their scope, writing nothing" do
        preview(other_branch.id)
        expect(response).to have_http_status(:unprocessable_entity)

        expect { confirm(other_branch.id) }.not_to change(ShiftAssignment, :count)
        expect(flash[:alert]).to eq(I18n.t("shift_templates.apply.branch_not_allowed"))
      end

      it "is offered only the branches they may assign to" do
        get apply_admin_shift_template_path(template)
        expect(response.body).to include(branch.name)
        expect(response.body).not_to include(%(value="#{other_branch.id}"))
      end
    end
  end
end
