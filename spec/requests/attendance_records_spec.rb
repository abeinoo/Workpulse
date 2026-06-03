require "rails_helper"

RSpec.describe "AttendanceRecords", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:branch)   { create(:branch, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }

  before { sign_in owner }

  describe "GET /attendance_records (source filter)" do
    let(:shift) { create(:shift, :fixed_time, business: business) }
    # Explicit, distinct names so the include/not_to-include assertions can never
    # collide on random Faker names (previously an intermittent failure).
    let(:mobile_user)    { create(:user, business: business, first_name: "Mobile", last_name: "Worker") }
    let(:biometric_user) { create(:user, business: business, first_name: "Biometric", last_name: "Worker") }
    let!(:mobile_record) do
      create(:attendance_record, :checked_out, user: mobile_user, business: business,
             branch: branch, check_in_source: "mobile", shift: shift)
    end
    let!(:biometric_record) do
      create(:attendance_record, :checked_out, user: biometric_user, business: business,
             branch: branch, check_in_source: "biometric_device", shift: shift)
    end

    it "returns all records when no source filter applied" do
      get attendance_records_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(mobile_record.user.full_name)
      expect(response.body).to include(biometric_record.user.full_name)
    end

    it "filters to only mobile records" do
      get attendance_records_path, params: { source: "mobile" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(mobile_record.user.full_name)
      expect(response.body).not_to include(biometric_record.user.full_name)
    end

    it "filters to only biometric_device records" do
      get attendance_records_path, params: { source: "biometric_device" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(biometric_record.user.full_name)
      expect(response.body).not_to include(mobile_record.user.full_name)
    end

    it "returns no records for a source with no matches" do
      get attendance_records_path, params: { source: "import" }
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(mobile_record.user.full_name)
      expect(response.body).not_to include(biometric_record.user.full_name)
    end
  end

  describe "manual attendance entry" do
    let!(:employee) { create(:user, business: business, manager: owner) }

    it "renders the new form for an authorized user" do
      get new_attendance_record_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("attendance.manual.title"))
    end

    it "creates a record and redirects to it" do
      expect {
        post attendance_records_path, params: {
          attendance_record: {
            user_id:        employee.id,
            work_date:      (Date.current - 1).iso8601,
            check_in_time:  "09:00",
            check_out_time: "17:00",
            notes:          "Reconstructed from sign-in sheet"
          }
        }
      }.to change(AttendanceRecord, :count).by(1)

      record = AttendanceRecord.order(:created_at).last
      expect(record.created_by).to eq(owner)
      expect(record.user).to eq(employee)
      expect(response).to redirect_to(attendance_record_path(record))
    end

    it "re-renders with an error when the date is already taken" do
      create(:attendance_record, user: employee, branch: branch,
             date: Date.current - 1, work_date: Date.current - 1)
      post attendance_records_path, params: {
        attendance_record: {
          user_id:       employee.id,
          work_date:     (Date.current - 1).iso8601,
          check_in_time: "09:00"
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("attendance.manual.errors.duplicate"))
    end

    it "is blocked for a user without manage_attendance" do
      role = create(:permission_role, :view_only, business: business)
      viewer = create(:user, business: business, permission_role: role)
      sign_in viewer
      get new_attendance_record_path
      expect(response).not_to have_http_status(:ok)
    end

    it "shows ALL business employees for a business-wide manager (not just managed)" do
      role = create(:permission_role, business: business,
                    permissions: %w[view_attendance manage_attendance],
                    permission_scopes: { "manage_attendance" => "business_wide" })
      wide_mgr  = create(:user, business: business, permission_role: role)
      unmanaged = create(:user, business: business, first_name: "Unmanaged", last_name: "Person")
      sign_in wide_mgr

      get new_attendance_record_path
      expect(response.body).to include("Unmanaged Person")

      get bulk_attendance_records_path
      expect(response.body).to include("Unmanaged Person")
    end

    it "limits a managed-scope manager to their hierarchy" do
      role = create(:permission_role, business: business,
                    permissions: %w[view_attendance manage_attendance],
                    permission_scopes: { "manage_attendance" => "managed_employees_only" })
      restricted = create(:user, business: business, permission_role: role)
      create(:user, business: business, manager: restricted, first_name: "My", last_name: "Report")
      outsider   = create(:user, business: business, first_name: "Outside", last_name: "Scope")
      sign_in restricted

      get new_attendance_record_path
      expect(response.body).to include("My Report")
      expect(response.body).not_to include("Outside Scope")
    end
  end

  describe "bulk manual attendance entry" do
    let!(:emp1) { create(:user, business: business, employee_code: "EMP001", manager: owner) }
    let!(:emp2) { create(:user, business: business, employee_code: "EMP002", manager: owner) }

    it "renders the bulk grid for an authorized user" do
      get bulk_attendance_records_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("attendance.manual.bulk.title"))
    end

    it "creates multiple records from grid rows" do
      expect {
        post bulk_create_attendance_records_path, params: {
          attendance_record_rows: {
            "1" => { user_id: emp1.id, work_date: "2026-06-01", check_in: "09:00", check_out: "17:00", notes: "a" },
            "2" => { user_id: emp2.id, work_date: "2026-06-01", check_in: "08:30", check_out: "16:30", notes: "b" }
          }
        }
      }.to change(AttendanceRecord, :count).by(2)
      expect(response).to redirect_to(attendance_records_path)
      expect(AttendanceRecord.where(created_by: owner).count).to eq(2)
    end

    it "saves nothing and re-renders when a row is invalid (all-or-nothing)" do
      expect {
        post bulk_create_attendance_records_path, params: {
          attendance_record_rows: {
            "1" => { user_id: emp1.id, work_date: "2026-06-01", check_in: "09:00" },
            "2" => { user_id: emp2.id, work_date: "bad", check_in: "09:00" }
          }
        }
      }.not_to change(AttendanceRecord, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "is blocked for a user without manage_attendance" do
      role   = create(:permission_role, :view_only, business: business)
      viewer = create(:user, business: business, permission_role: role)
      sign_in viewer
      get bulk_attendance_records_path
      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "manual attendance CSV import" do
    let!(:emp1) { create(:user, business: business, employee_code: "EMP001", manager: owner) }
    let!(:emp2) { create(:user, business: business, employee_code: "EMP002", manager: owner) }

    def upload(csv)
      Rack::Test::UploadedFile.new(
        StringIO.new(csv), "text/csv", original_filename: "manual.csv"
      )
    end

    let(:csv) do
      <<~CSV
        employee_code,work_date,check_in,check_out,notes
        EMP001,2026-06-01,09:00,17:00,Sign-in sheet
        EMP002,2026-06-01,20:00,04:00,Overnight
        NOPE,2026-06-01,09:00,,Unknown employee
      CSV
    end

    it "downloads the CSV template" do
      get import_template_attendance_records_path
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
      expect(response.body).to include("employee_code,work_date,check_in")
    end

    it "renders a preview with valid and invalid counts" do
      post preview_import_attendance_records_path, params: { csv_file: upload(csv) }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("attendance.manual.import.preview_title"))
      expect(response.body).to include("EMP001")
      expect(response.body).to include("NOPE") # invalid row surfaced
    end

    it "commits valid rows on confirm and ignores the invalid one" do
      rows_json = [
        { user_id: emp1.id, work_date: "2026-06-01", check_in: "09:00", check_out: "17:00", notes: "x" },
        { user_id: emp2.id, work_date: "2026-06-01", check_in: "20:00", check_out: "04:00", notes: "y" }
      ].to_json

      expect {
        post confirm_import_attendance_records_path, params: { rows_json: rows_json }
      }.to change(AttendanceRecord, :count).by(2)
      expect(response).to redirect_to(attendance_records_path)
    end

    it "rejects a non-CSV upload" do
      bad = Rack::Test::UploadedFile.new(StringIO.new("x"), "image/png", original_filename: "x.png")
      post preview_import_attendance_records_path, params: { csv_file: bad }
      expect(response).to redirect_to(import_attendance_records_path)
    end

    it "is blocked for a user without manage_attendance" do
      role   = create(:permission_role, :view_only, business: business)
      viewer = create(:user, business: business, permission_role: role)
      sign_in viewer
      get import_attendance_records_path
      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "locale persistence across login" do
    it "unauthenticated locale switch persists in session" do
      sign_out owner
      patch set_locale_path, params: { locale: "ar" }
      expect(session[:locale]).to eq("ar")
    end

    it "locale switch for authenticated user updates both session and user record" do
      patch set_locale_path, params: { locale: "ar" }
      expect(session[:locale]).to eq("ar")
      expect(owner.reload.preferred_locale).to eq("ar")
    end
  end
end
