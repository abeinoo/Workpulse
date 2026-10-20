require "rails_helper"

# Characterization (Milestone 2 Pilot 1, M1) — CURRENT BiometricPunchLog rules:
# validations and predicates, query scopes, who writes logs (device punches and
# mobile rejections) and who can see them in the admin. Admin filters/ordering
# are in spec/requests/admin/biometric_punch_logs_spec.rb.
#
# Visibility: until SEC-M2-8 was fixed any user past Admin::BaseController's gate
# saw every log of the business; it now follows BiometricPunchLogPolicy
# (manage_devices: the business; view_attendance: its scope — D-S8-1), pinned
# below and in spec/requests/security/biometric_punch_logs_authorization_spec.rb.
RSpec.describe "Characterization: biometric punch logs", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business, first_name: "Ahmed") }

  describe "model" do
    it "accepts exactly the documented actions and sources" do
      expect(BiometricPunchLog::ACTIONS).to eq(
        %w[check_in check_in_updated check_out rejected_no_assignment rejected_spam rejected_not_allowed error]
      )
      expect(BiometricPunchLog::SOURCES).to eq(%w[biometric mobile])

      expect(build(:biometric_punch_log, business: business, action: "deleted")).not_to be_valid
      expect(build(:biometric_punch_log, business: business, source: "csv")).not_to be_valid
    end

    it "requires business, punched_at and received_at; device, employee and record are optional" do
      expect(build(:biometric_punch_log, business: nil)).not_to be_valid
      expect(build(:biometric_punch_log, business: business, punched_at: nil)).not_to be_valid
      expect(build(:biometric_punch_log, business: business, received_at: nil)).not_to be_valid
      expect(build(:biometric_punch_log, business: business, biometric_device: nil, employee: nil, attendance_record: nil)).to be_valid
    end

    it "classifies actions as success or rejected" do
      outcomes = BiometricPunchLog::ACTIONS.to_h do |action|
        log = build(:biometric_punch_log, action: action)
        [ action, [ log.success?, log.rejected? ] ]
      end

      expect(outcomes).to eq(
        "check_in"               => [ true,  false ],
        "check_in_updated"       => [ true,  false ],
        "check_out"              => [ true,  false ],
        "rejected_no_assignment" => [ false, true ],
        "rejected_spam"          => [ false, true ],
        "rejected_not_allowed"   => [ false, true ],
        "error"                  => [ false, false ]
      )
    end

    it "scopes by business, employee and source, and orders recent by received_at" do
      older   = create(:biometric_punch_log, business: business, employee: employee, received_at: 2.hours.ago)
      newer   = create(:biometric_punch_log, business: business, received_at: 1.hour.ago, source: "mobile")
      foreign = create(:biometric_punch_log, business: other)

      expect(BiometricPunchLog.for_business(business)).to contain_exactly(older, newer)
      expect(BiometricPunchLog.for_employee(employee)).to contain_exactly(older)
      expect(BiometricPunchLog.from_source("mobile")).to contain_exactly(newer)
      expect(BiometricPunchLog.for_business(business).recent).to eq([ newer, older ])
      expect(foreign).to be_persisted
    end
  end

  describe "mobile attendance rejection" do
    it "writes a mobile-source rejected_not_allowed log (no device) when mobile attendance is not allowed" do
      branch = create(:branch, business: business)
      create(:shift_assignment, user: employee, branch: branch, shift: create(:shift, :fixed_time, business: business),
                                effective_from: 1.month.ago.to_date)
      employee.update_column(:allow_mobile_attendance, false)
      sign_in employee

      expect { post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json }
        .to change(BiometricPunchLog, :count).by(1)

      expect(response).to have_http_status(:forbidden)
      expect(BiometricPunchLog.last).to have_attributes(
        business_id: business.id, employee_id: employee.id, biometric_device_id: nil,
        source: "mobile", action: "rejected_not_allowed",
        error_message: I18n.t("api.punch.mobile_attendance_not_allowed")
      )
    end
  end

  # SEC-M2-8 (fixed; decisions D-S8-1 / D-S8-2): punch logs need manage_devices
  # (the whole business) or view_attendance (its scope) — the admin gate alone no
  # longer suffices. The full matrix is in
  # spec/requests/security/biometric_punch_logs_authorization_spec.rb.
  describe "admin visibility (BiometricPunchLogPolicy)" do
    let!(:own_log)     { create(:biometric_punch_log, business: business, employee: employee) }
    let!(:foreign_log) { create(:biometric_punch_log, business: other, employee: create(:user, business: other)) }

    def log_links
      Nokogiri::HTML(response.body).css("a").map { |a| a["href"] }
    end

    it "refuses a user holding only view_employees (an admin-gate permission, but no device or attendance permission)" do
      sign_in api_user_with(business, :view_employees)

      get admin_biometric_punch_logs_path
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))

      get admin_biometric_punch_log_path(own_log)
      expect(response).to redirect_to(root_path)
    end

    it "shows every business log, and no other business's, to a manage_devices holder" do
      sign_in api_user_with(business, :manage_devices)

      get admin_biometric_punch_logs_path
      expect(response).to have_http_status(:ok)
      expect(log_links).to include(admin_biometric_punch_log_path(own_log))
      expect(log_links).not_to include(admin_biometric_punch_log_path(foreign_log))

      get admin_biometric_punch_log_path(own_log)
      expect(response).to have_http_status(:ok)
    end

    it "redirects a user with none of the admin-gate permissions" do
      sign_in api_user_with(business, :view_requests)

      get admin_biometric_punch_logs_path

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
    end

    it "returns 404 for another business's log" do
      sign_in owner
      get admin_biometric_punch_log_path(foreign_log)
      expect(response).to have_http_status(:not_found)
    end
  end
end
