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

      it "includes the signed-in super_admin in the list (owner visibility fix)" do
        get admin_users_path
        expect(response.body).to include(super_admin.first_name)
      end

      context "employee status badge column" do
        it "renders a green (success) badge for active employees" do
          create(:user, business: business, active: true, first_name: "Active")
          get admin_users_path(status: "active")
          expect(response.body).to include("badge badge-success")
        end

        it "renders a red (danger) badge for inactive employees" do
          create(:user, business: business, active: false, first_name: "Inactive")
          get admin_users_path(status: "inactive")
          expect(response.body).to include("badge badge-danger")
        end
      end

      context "registration status column" do
        it "renders a green (success) Registered badge when the account has a password" do
          create(:user, business: business, first_name: "Onboarded")
          get admin_users_path(status: "active")
          expect(response.body).to include("badge badge-success")
          expect(response.body).to include(I18n.t("admin.users.registered"))
        end

        it "renders a yellow (warning) Pending Registration badge when no password is set" do
          create(:user, business: business, first_name: "Invited",
                        password: nil, password_confirmation: nil)
          get admin_users_path(status: "active")
          expect(response.body).to include("badge badge-warning")
          expect(response.body).to include(I18n.t("admin.users.pending_registration"))
        end
      end

      context "quick call column" do
        it "renders a tel: link when the employee has a phone number" do
          create(:user, business: business, phone_number: "0555123456", first_name: "Callable")
          get admin_users_path(status: "active")
          expect(response.body).to include('href="tel:0555123456"')
        end

        it "renders a disabled control with a tooltip when no phone number is present" do
          create(:user, business: business, phone_number: nil, email: "nophone@example.com", first_name: "Unreachable")
          get admin_users_path(status: "active")
          expect(response.body).to include('aria-disabled="true"')
          expect(response.body).to include(I18n.t("admin.users.no_phone"))
        end
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

  describe "GET /admin/users/:id" do
    let!(:target_user) { create(:user, business: business) }

    context "signed in as super_admin" do
      before { sign_in super_admin }

      it "returns 200" do
        get admin_user_path(target_user)
        expect(response).to have_http_status(:ok)
      end

      it "shows the initials avatar when no profile_photo is attached" do
        get admin_user_path(target_user)
        expect(response.body).to include("avatar-placeholder")
        expect(response.body).not_to include("avatar-img")
      end

      it "shows the profile photo img tag when profile_photo is attached" do
        target_user.profile_photo.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
          filename:     "photo.png",
          content_type: "image/png"
        )
        get admin_user_path(target_user)
        expect(response.body).to include("avatar-img")
        # Unified wrapper ensures photo and initials share identical dimensions/styling
        expect(response.body).to include('class="avatar avatar--lg"')
      end

      it "does not show the documents section when no IDs are attached" do
        get admin_user_path(target_user)
        expect(response.body).not_to include("attachment-grid")
      end

      it "shows the documents section when national_id_front is attached" do
        target_user.national_id_front.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
          filename:     "id_front.png",
          content_type: "image/png"
        )
        get admin_user_path(target_user)
        expect(response.body).to include("attachment-grid")
        expect(response.body).to include("attachment-viewer--image")
      end

      it "renders a PDF viewer card when national_id_front is a PDF" do
        target_user.national_id_front.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
          filename:     "id_front.pdf",
          content_type: "application/pdf"
        )
        get admin_user_path(target_user)
        expect(response.body).to include("attachment-viewer--pdf")
        expect(response.body).to include("id_front.pdf")
      end
    end

    context "signed in as a different employee (not authorized)" do
      before { sign_in employee }

      it "redirects away" do
        get admin_user_path(target_user)
        expect(response).to redirect_to(root_path)
      end
    end

    context "not signed in" do
      it "redirects to sign in" do
        get admin_user_path(target_user)
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

    it "prevents self-deletion and redirects with an alert (self-deletion guard fix)" do
      expect { delete admin_user_path(super_admin) }
        .not_to change(User, :count)
      expect(response).to redirect_to(admin_users_path)
      follow_redirect!
      expect(response.body).to include(I18n.t("flash.cannot_delete_self"))
    end
  end

  # ── Attachment upload ──────────────────────────────────────────────────────

  describe "PATCH /admin/users/:id — profile_photo upload" do
    let!(:target_user) { create(:user, business: business) }
    let(:png_file) do
      Rack::Test::UploadedFile.new(
        Rails.root.join("spec/fixtures/files/test_image.png"),
        "image/png"
      )
    end

    context "signed in as owner" do
      before { sign_in super_admin }

      it "attaches the profile_photo and redirects" do
        patch admin_user_path(target_user),
          params: { user: { profile_photo: png_file, remove_profile_photo: "0" } }

        expect(response).to redirect_to(admin_users_path)
        expect(target_user.reload.profile_photo).to be_attached
      end

      it "rejects a GIF and returns unprocessable_entity" do
        gif = Rack::Test::UploadedFile.new(
          StringIO.new("GIF89a"), "image/gif", original_filename: "bad.gif"
        )
        patch admin_user_path(target_user),
          params: { user: { profile_photo: gif, remove_profile_photo: "0" } }

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context "signed in as a different employee (not authorized)" do
      let(:other_employee) { create(:user, business: business) }

      before { sign_in other_employee }

      it "is redirected away (not authorized)" do
        patch admin_user_path(target_user),
          params: { user: { profile_photo: png_file, remove_profile_photo: "0" } }

        expect(response).to redirect_to(root_path)
      end
    end

    context "not signed in" do
      it "redirects to sign in" do
        patch admin_user_path(target_user),
          params: { user: { profile_photo: png_file, remove_profile_photo: "0" } }

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe "PATCH /admin/users/:id — national_id_front upload" do
    let!(:target_user) { create(:user, business: business) }
    let(:pdf_file) do
      Rack::Test::UploadedFile.new(
        Rails.root.join("spec/fixtures/files/test_document.pdf"),
        "application/pdf"
      )
    end

    before { sign_in super_admin }

    it "attaches a PDF as national_id_front" do
      patch admin_user_path(target_user),
        params: { user: { national_id_front: pdf_file, remove_national_id_front: "0" } }

      expect(response).to redirect_to(admin_users_path)
      expect(target_user.reload.national_id_front).to be_attached
    end

    it "attaches a PNG as national_id_front" do
      png = Rack::Test::UploadedFile.new(
        Rails.root.join("spec/fixtures/files/test_image.png"),
        "image/png"
      )
      patch admin_user_path(target_user),
        params: { user: { national_id_front: png, remove_national_id_front: "0" } }

      expect(response).to redirect_to(admin_users_path)
      expect(target_user.reload.national_id_front).to be_attached
    end
  end

  describe "PATCH /admin/users/:id — remove profile_photo" do
    let!(:target_user) { create(:user, business: business) }

    before do
      sign_in super_admin
      target_user.profile_photo.attach(
        io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
        filename:     "photo.png",
        content_type: "image/png"
      )
    end

    it "purges the profile_photo when remove flag is set" do
      expect(target_user.profile_photo).to be_attached

      patch admin_user_path(target_user),
        params: { user: { remove_profile_photo: "1" } }

      expect(response).to redirect_to(admin_users_path)
      expect(target_user.reload.profile_photo).not_to be_attached
    end

    it "does not purge when remove flag is 0" do
      patch admin_user_path(target_user),
        params: { user: { remove_profile_photo: "0" } }

      expect(target_user.reload.profile_photo).to be_attached
    end
  end

  # ── PATCH /admin/users/:id/toggle_active ──────────────────────────────────
  describe "PATCH /admin/users/:id/toggle_active" do
    let!(:target_user) { create(:user, business: business, active: true) }

    context "signed in as super_admin" do
      before { sign_in super_admin }

      it "deactivates an active user and redirects with notice" do
        patch toggle_active_admin_user_path(target_user)
        expect(target_user.reload.active).to be false
        expect(response).to redirect_to(admin_users_path)
        follow_redirect!
        expect(response.body).to include(target_user.full_name)
      end

      it "reactivates an inactive user" do
        target_user.update!(active: false)
        patch toggle_active_admin_user_path(target_user)
        expect(target_user.reload.active).to be true
      end

      it "prevents deactivating the business owner with a specific message" do
        patch toggle_active_admin_user_path(super_admin)
        expect(super_admin.reload.active).to be true
        expect(response).to redirect_to(admin_users_path)
        follow_redirect!
        expect(response.body).to include(I18n.t("flash.cannot_deactivate_owner"))
      end
    end

    context "signed in as a regular employee" do
      before { sign_in employee }

      it "is redirected (not authorized)" do
        patch toggle_active_admin_user_path(target_user)
        expect(response).to redirect_to(root_path)
        expect(target_user.reload.active).to be true
      end
    end

    context "not signed in" do
      it "redirects to sign in" do
        patch toggle_active_admin_user_path(target_user)
        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  # ── Inactive user session invalidation ───────────────────────────────────
  describe "existing session blocked when user is deactivated" do
    it "signs out and redirects to login when a signed-in user is deactivated" do
      sign_in employee
      employee.update_column(:active, false)

      get admin_users_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
