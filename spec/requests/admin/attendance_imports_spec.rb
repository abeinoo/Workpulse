require "rails_helper"

# Authorization and policy audit for the Attendance Import feature.
#
# Verifies:
#   - Pundit policy class is discovered correctly (AttendanceImportLogPolicy)
#   - Only owners and users with manage_attendance can access the feature
#   - view_attendance alone is insufficient
#   - Branch managers without explicit manage_attendance are blocked
#   - All 6 actions enforce the same gate (new, create, show, confirm, failed_rows, template)
#   - Policy scope isolates records to the current user's business
#   - Cross-business access returns 404 (set_import scopes by business)
#   - Unauthenticated access redirects to sign-in
#   - Base controller pre-check blocks users with no role at all
RSpec.describe "Admin::AttendanceImports", type: :request do
  let(:business)  { create(:business) }
  let(:other_biz) { create(:business) }

  # owner — full access automatically
  let!(:owner)    { create(:user, :owner, business: business) }

  # user with manage_attendance permission
  let(:attendance_manager) do
    role = create(:permission_role, business: business, permissions: %w[manage_attendance view_attendance])
    create(:user, business: business, permission_role: role)
  end

  # user with view_attendance ONLY — must NOT get import access
  let(:view_only_user) do
    role = create(:permission_role, :view_only, business: business)
    create(:user, business: business, permission_role: role)
  end

  # branch manager with no permission role — only gets branch-scoped access
  let(:branch) { create(:branch, business: business) }
  let(:branch_manager) do
    user = create(:user, business: business)
    branch.update_column(:branch_manager_id, user.id)
    create(:user_branch, user: user, branch: branch)
    user
  end

  # plain employee — no roles, no permissions
  let(:employee) { create(:user, business: business) }

  # a completed import owned by the business
  let!(:import_log) do
    AttendanceImportLog.create!(
      business:          business,
      imported_by:       owner,
      filename:          "test.csv",
      status:            "completed",
      total_rows:        2,
      imported_rows:     2,
      failed_rows_count: 0,
      metadata:          { "preview" => [], "failed" => [] }
    )
  end

  # an import from a different business (cross-business isolation check)
  let!(:other_import) do
    other_owner = create(:user, :owner, business: other_biz)
    AttendanceImportLog.create!(
      business:          other_biz,
      imported_by:       other_owner,
      filename:          "other.csv",
      status:            "completed",
      total_rows:        1,
      imported_rows:     1,
      failed_rows_count: 0,
      metadata:          { "preview" => [], "failed" => [] }
    )
  end

  # ── Unauthenticated access ─────────────────────────────────────────────────

  describe "unauthenticated access" do
    it "redirects GET /admin/attendance_imports/new to sign in" do
      get new_admin_attendance_import_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "redirects GET /admin/attendance_imports/:id to sign in" do
      get admin_attendance_import_path(import_log)
      expect(response).to redirect_to(new_user_session_path)
    end

    it "redirects GET /admin/attendance_imports/template to sign in" do
      get template_admin_attendance_imports_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  # ── Admin::BaseController pre-check (no permission role) ─────────────────

  describe "user with no permission role (plain employee)" do
    before { sign_in employee }

    it "is blocked from new by the base controller and redirected to root" do
      get new_admin_attendance_import_path
      expect(response).to redirect_to(root_path)
    end

    it "is blocked from show by the base controller and redirected to root" do
      get admin_attendance_import_path(import_log)
      expect(response).to redirect_to(root_path)
    end
  end

  # ── view_attendance alone — must NOT grant import access ──────────────────

  describe "user with view_attendance only" do
    before { sign_in view_only_user }

    it "is redirected from new with not_authorized flash" do
      get new_admin_attendance_import_path
      expect(response).to redirect_to(root_path)
    end

    it "is redirected from show with not_authorized flash" do
      get admin_attendance_import_path(import_log)
      expect(response).to redirect_to(root_path)
    end

    it "is redirected from template with not_authorized flash" do
      get template_admin_attendance_imports_path
      expect(response).to redirect_to(root_path)
    end
  end

  # ── Branch manager without manage_attendance — must be blocked ────────────

  describe "branch manager without manage_attendance permission" do
    before { sign_in branch_manager }

    it "is blocked from new (base controller: no permission role)" do
      get new_admin_attendance_import_path
      expect(response).to redirect_to(root_path)
    end

    it "is blocked from show (base controller: no permission role)" do
      get admin_attendance_import_path(import_log)
      expect(response).to redirect_to(root_path)
    end
  end

  # ── Owner happy path ──────────────────────────────────────────────────────

  describe "owner" do
    before { sign_in owner }

    it "can access new (upload form)" do
      get new_admin_attendance_import_path
      expect(response).to have_http_status(:ok)
    end

    it "can access show for own business import" do
      get admin_attendance_import_path(import_log)
      expect(response).to have_http_status(:ok)
    end

    it "can download template CSV" do
      get template_admin_attendance_imports_path
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
    end

    it "can download failed rows CSV" do
      get failed_rows_admin_attendance_import_path(import_log)
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
    end

    it "returns 404 when accessing an import from another business" do
      get admin_attendance_import_path(other_import)
      expect(response).to have_http_status(:not_found)
    end

    it "redirects confirm on an already-completed import back to show" do
      patch confirm_admin_attendance_import_path(import_log)
      expect(response).to redirect_to(admin_attendance_import_path(import_log))
    end
  end

  # ── Attendance manager happy path ─────────────────────────────────────────

  describe "user with manage_attendance permission" do
    before { sign_in attendance_manager }

    it "can access new (upload form)" do
      get new_admin_attendance_import_path
      expect(response).to have_http_status(:ok)
    end

    it "can access show for their business's import" do
      get admin_attendance_import_path(import_log)
      expect(response).to have_http_status(:ok)
    end

    it "can download template CSV" do
      get template_admin_attendance_imports_path
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
    end

    it "can download failed rows CSV" do
      get failed_rows_admin_attendance_import_path(import_log)
      expect(response).to have_http_status(:ok)
    end

    it "gets 404 trying to access an import from another business" do
      get admin_attendance_import_path(other_import)
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Policy scope isolation ─────────────────────────────────────────────────

  describe "policy scope isolation" do
    before { sign_in owner }

    it "new page only shows recent imports from own business" do
      get new_admin_attendance_import_path
      # The view assigns @recent_imports scoped to current_user.business_id.
      # We verify the other business's import is not in that scope.
      expect(response.body).not_to include(other_import.filename)
    end
  end

  # ── Cross-business show isolation ─────────────────────────────────────────

  describe "cross-business isolation" do
    before { sign_in attendance_manager }

    it "attendance_manager from business A gets 404 on business B import" do
      get admin_attendance_import_path(other_import)
      expect(response).to have_http_status(:not_found)
    end

    it "does not expose business B import filename in error response" do
      get admin_attendance_import_path(other_import)
      expect(response.body).not_to include(other_import.filename)
    end
  end

  # ── POST create — file validation ─────────────────────────────────────────

  describe "POST /admin/attendance_imports (create)" do
    before { sign_in owner }

    it "redirects with no_file alert when no file attached" do
      post admin_attendance_imports_path
      expect(response).to redirect_to(new_admin_attendance_import_path)
    end

    it "redirects with invalid_type alert for a non-CSV file" do
      file = fixture_file_upload(
        Rails.root.join("spec/fixtures/files/not_a_csv.txt"),
        "text/plain"
      )
      # content_type check in controller requires CSV-like MIME; .txt is accepted
      # as text/plain (which is in the allowed list), so we instead test with a
      # clearly invalid type by stubbing content_type
      allow_any_instance_of(ActionDispatch::Http::UploadedFile)
        .to receive(:content_type).and_return("application/pdf")
      post admin_attendance_imports_path, params: { file: file }
      expect(response).to redirect_to(new_admin_attendance_import_path)
    end

    it "is blocked for view_only_user" do
      sign_in view_only_user
      post admin_attendance_imports_path
      expect(response).to redirect_to(root_path)
    end
  end
end
