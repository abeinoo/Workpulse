require "rails_helper"

RSpec.describe "Admin::Employees", type: :request do
  let(:admin)         { create(:user, :admin) }
  let(:employee_user) { create(:user) }

  describe "GET /admin/employees" do
    context "when signed in as admin" do
      before { sign_in admin }

      it "returns 200" do
        get admin_employees_path
        expect(response).to have_http_status(:ok)
      end
    end

    context "when signed in as a regular employee" do
      before { sign_in employee_user }

      it "redirects away" do
        get admin_employees_path
        expect(response).to redirect_to(root_path)
      end
    end

    context "when not signed in" do
      it "redirects to sign in" do
        get admin_employees_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "POST /admin/employees" do
    before { sign_in admin }

    let(:valid_params) do
      {
        employee: {
          full_name:       "Sara Ahmed",
          phone_number:    "+966050000099",
          employee_number: "EMP-0099",
          status:          "active"
        }
      }
    end

    it "creates the employee and redirects" do
      expect { post admin_employees_path, params: valid_params }
        .to change(Employee, :count).by(1)

      expect(response).to redirect_to(admin_employees_path)
    end

    it "renders new with errors on invalid params" do
      post admin_employees_path, params: { employee: { full_name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /admin/employees/:id" do
    before { sign_in admin }

    let!(:employee) { create(:employee) }

    it "updates the employee and redirects" do
      patch admin_employee_path(employee), params: { employee: { full_name: "Updated Name" } }
      expect(employee.reload.full_name).to eq("Updated Name")
      expect(response).to redirect_to(admin_employees_path)
    end
  end

  describe "DELETE /admin/employees/:id" do
    before { sign_in admin }

    let!(:employee) { create(:employee) }

    it "destroys the employee and redirects" do
      expect { delete admin_employee_path(employee) }
        .to change(Employee, :count).by(-1)

      expect(response).to redirect_to(admin_employees_path)
    end
  end
end
