require "rails_helper"

RSpec.describe "Admin::Settings", type: :request do
  let(:business)    { create(:business, employee_code_start: 1) }
  let(:super_admin) { create(:user, :super_admin, business: business) }

  before { sign_in super_admin }

  describe "GET /admin/settings" do
    it "renders the employee starting-number field" do
      get admin_settings_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("admin.settings.employee_code_start_label"))
    end
  end

  describe "PATCH /admin/settings" do
    it "updates the configurable starting number" do
      patch admin_settings_path, params: { business: { employee_code_start: 500 } }
      expect(response).to redirect_to(admin_settings_path)
      expect(business.reload.employee_code_start).to eq(500)
    end

    it "drives the next generated employee_code for new employees" do
      patch admin_settings_path, params: { business: { employee_code_start: 500 } }
      employee = business.users.create!(first_name: "New", last_name: "Hire",
                                        email: "newhire@example.com")
      expect(employee.employee_code).to eq("500")
    end

    it "rejects an invalid starting number" do
      patch admin_settings_path, params: { business: { employee_code_start: 0 } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(business.reload.employee_code_start).to eq(1)
    end
  end
end
