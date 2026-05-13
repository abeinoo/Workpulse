require "rails_helper"

RSpec.describe "Admin::Users", type: :request do
  let(:business)    { create(:business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  let(:employee)    { create(:user, business: business) }

  describe "GET /admin/users" do
    context "signed in as super_admin" do
      before { sign_in super_admin }

      it "returns 200" do
        get admin_users_path
        expect(response).to have_http_status(:ok)
      end
    end

    context "signed in as employee" do
      before { sign_in employee }

      it "redirects with an alert" do
        get admin_users_path
        expect(response).to redirect_to(root_path)
      end
    end

    context "not signed in" do
      it "redirects to sign in" do
        get admin_users_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "POST /admin/users" do
    before { sign_in super_admin }

    let(:valid_params) do
      {
        user: {
          first_name:   "Fatima",
          last_name:    "Al-Rashid",
          email:        "fatima@example.com",
          role:         "employee",
          business_id:  business.id
        }
      }
    end

    it "creates a new user and redirects" do
      expect { post admin_users_path, params: valid_params }
        .to change(User, :count).by(1)
      expect(response).to redirect_to(admin_users_path)
    end

    it "renders new with errors on invalid params" do
      post admin_users_path, params: { user: { first_name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /admin/users/:id" do
    before { sign_in super_admin }

    let!(:target_user) { create(:user, business: business, first_name: "Ali") }

    it "updates the user and redirects" do
      patch admin_user_path(target_user), params: { user: { first_name: "Ahmed" } }
      expect(target_user.reload.first_name).to eq("Ahmed")
      expect(response).to redirect_to(admin_users_path)
    end
  end

  describe "DELETE /admin/users/:id" do
    before { sign_in super_admin }

    let!(:target_user) { create(:user, business: business) }

    it "destroys the user and redirects" do
      expect { delete admin_user_path(target_user) }
        .to change(User, :count).by(-1)
      expect(response).to redirect_to(admin_users_path)
    end
  end
end
