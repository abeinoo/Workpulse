require "rails_helper"

# Characterization (Department + JobTitle pilot, M1 gap DJ2) — the CURRENT
# /admin/departments behaviour: CRUD, restricted deletion, authorization
# (manage_evaluation_templates or manage_settings) and business isolation.
RSpec.describe "Characterization: Department admin", type: :request do
  let(:business) { create(:business) }
  # manage_evaluation_templates depends on view_performance_dashboard (PermissionRole dependency).
  let(:admin)    { api_user_with(business, :view_performance_dashboard, :manage_evaluation_templates) }

  describe "with manage_evaluation_templates" do
    before { sign_in admin }

    it "lists the business's departments, active and inactive, but not another business's" do
      active   = create(:department, business: business, name: "Active Dept")
      inactive = create(:department, business: business, name: "Inactive Dept", active: false)
      foreign  = create(:department, business: create(:business), name: "Foreign Dept")
      get admin_departments_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(active.name, inactive.name)
      expect(response.body).not_to include(foreign.name)
    end

    it "creates a normalized department in the actor's business and redirects to the index" do
      post admin_departments_path, params: { department: { name: "  Front   Desk ", active: "1", business_id: create(:business).id } }
      expect(response).to redirect_to(admin_departments_path)
      expect(flash[:notice]).to eq(I18n.t("admin.departments.created"))
      expect(Department.find_by!(name: "Front Desk").business_id).to eq(business.id)
    end

    it "re-renders 422 for an invalid or duplicate name" do
      create(:department, business: business, name: "Front Desk")
      post admin_departments_path, params: { department: { name: "front desk", active: "1" } }
      expect(response).to have_http_status(:unprocessable_content)
      post admin_departments_path, params: { department: { name: "", active: "1" } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "updates the name and deactivates (soft delete)" do
      department = create(:department, business: business, name: "Old Name")
      patch admin_department_path(department), params: { department: { name: "New Name", active: "0" } }
      expect(response).to redirect_to(admin_departments_path)
      expect(flash[:notice]).to eq(I18n.t("admin.departments.updated"))
      expect(department.reload).to have_attributes(name: "New Name", active: false)
    end

    it "destroys a department without dependents" do
      department = create(:department, business: business)
      delete admin_department_path(department)
      expect(response).to redirect_to(admin_departments_path)
      expect(flash[:notice]).to eq(I18n.t("admin.departments.destroyed"))
      expect(Department.exists?(department.id)).to be(false)
    end

    it "refuses to destroy a department with dependents, redirecting with the model error as alert" do
      department = create(:department, business: business)
      EvaluationTemplate.create!(business: business, department: department, name: "Template")
      delete admin_department_path(department)
      expect(response).to redirect_to(admin_departments_path)
      expect(flash[:alert]).to eq("Cannot delete record because dependent evaluation templates exist")
      expect(Department.exists?(department.id)).to be(true)
    end

    it "returns 404 for another business's department (edit, update, destroy)" do
      foreign = create(:department, business: create(:business), name: "Foreign")
      get edit_admin_department_path(foreign)
      expect(response).to have_http_status(:not_found)
      sign_in admin
      patch admin_department_path(foreign), params: { department: { name: "Hijacked" } }
      expect(response).to have_http_status(:not_found)
      sign_in admin
      delete admin_department_path(foreign)
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.name).to eq("Foreign")
    end
  end

  describe "authorization" do
    it "is also available with manage_settings" do
      sign_in api_user_with(business, :manage_settings)
      get admin_departments_path
      expect(response).to have_http_status(:ok)
    end

    it "is refused with admin access but neither manage_evaluation_templates nor manage_settings" do
      sign_in api_user_with(business, :view_employees, :manage_employees)
      get admin_departments_path
      expect(response).to redirect_to(root_path)
      sign_in api_user_with(business, :view_employees, :manage_employees)
      expect { post admin_departments_path, params: { department: { name: "Nope", active: "1" } } }
        .not_to change(Department, :count)
      expect(response).to redirect_to(root_path)
    end

    it "is refused without admin access at all" do
      sign_in create(:user, business: business)
      get admin_departments_path
      expect(response).to redirect_to(root_path)
    end
  end
end
