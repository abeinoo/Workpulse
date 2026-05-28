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
    before { sign_in owner }

    it "returns 200" do
      get apply_admin_shift_template_path(template)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /admin/shift_templates/:id/preview_apply" do
    let(:emp) { create(:user, business: business) }

    before do
      sign_in owner
      create(:shift_template_entry,
             shift_template: template,
             shift:          shift,
             branch:         nil,
             starts_on:      Date.current,
             ends_on:        Date.current + 30.days)
    end

    it "returns 200 and renders preview" do
      post preview_apply_admin_shift_template_path(template), params: {
        employee_ids: [ emp.id ]
      }
      expect(response).to have_http_status(:ok)
    end

    it "re-renders apply with error when no employees selected" do
      post preview_apply_admin_shift_template_path(template), params: {
        employee_ids: []
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /admin/shift_templates/:id/apply_confirm" do
    let(:emp) { create(:user, business: business) }

    before do
      sign_in owner
      create(:shift_template_entry,
             shift_template: template,
             shift:          shift,
             branch:         nil,
             starts_on:      Date.current,
             ends_on:        Date.current + 30.days)
    end

    it "creates assignments and redirects to template show" do
      expect {
        post apply_confirm_admin_shift_template_path(template), params: {
          employee_ids: [ emp.id ]
        }
      }.to change(ShiftAssignment, :count).by(1)
      expect(response).to redirect_to(admin_shift_template_path(template))
    end

    it "redirects with alert when no employees selected" do
      post apply_confirm_admin_shift_template_path(template), params: {
        employee_ids: []
      }
      expect(response).to redirect_to(apply_admin_shift_template_path(template))
    end
  end
end
