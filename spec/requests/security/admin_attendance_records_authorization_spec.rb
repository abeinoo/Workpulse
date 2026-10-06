require "rails_helper"

# SEC-M2-2: Admin::AttendanceRecordsController called no policy and looked
# records up business-wide, so any user past Admin::BaseController's broad
# gate (view_employees, view_payroll …) could rewrite any employee's — or
# their own — check-in/check-out through Attendance::AdjustmentService, which
# changes pay. It now uses the same policy_scope + AttendanceRecordPolicy as
# AttendanceRecordsController: business + view_attendance data scope for the
# lookup, manage_attendance for the change.
RSpec.describe "Security: admin attendance record changes", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }

  let(:employee_a) { create(:user, business: business) }
  let(:employee_b) { create(:user, business: business) }

  # The attendance_record factory assigns the employee to the record's branch.
  let!(:record_a) { create(:attendance_record, :checked_out, business: business, user: employee_a, branch: branch_a) }
  let!(:record_b) { create(:attendance_record, :checked_out, business: business, user: employee_b, branch: branch_b) }

  def change_check_in(record, hours_earlier: 2)
    new_check_in = (record.check_in_at - hours_earlier.hours).in_time_zone.strftime("%Y-%m-%dT%H:%M")
    patch admin_attendance_record_path(record),
          params: { attendance_record: { check_in_at: new_check_in, reason: "Correction from sign-in sheet" } }
  end

  describe "without manage_attendance" do
    # Every permission that opens Admin::BaseController for a default manager,
    # business-wide, but not manage_attendance.
    let(:viewer) do
      api_user_with(business, :view_employees, :view_attendance, :view_payroll,
                    scopes: { "view_employees" => "business", "view_attendance" => "business" })
    end

    before { sign_in viewer }

    it "cannot change another employee's record" do
      original = record_a.check_in_at
      change_check_in(record_a)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      expect(record_a.reload.check_in_at).to eq(original)
    end

    it "cannot change their own record" do
      own = create(:attendance_record, :checked_out, business: business, user: viewer, branch: branch_a)
      original = own.check_in_at
      change_check_in(own)
      expect(response).to redirect_to(root_path)
      expect(own.reload.check_in_at).to eq(original)
    end

    it "can still view a record inside their view_attendance scope, without the edit form" do
      get admin_attendance_record_path(record_a)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("attendance.records.save_changes"))
    end
  end

  describe "with manage_attendance (business scope)" do
    let(:manager) do
      api_user_with(business, :view_attendance, :manage_attendance,
                    scopes: { "view_attendance" => "business", "manage_attendance" => "business" })
    end

    before { sign_in manager }

    it "changes a same-business record and shows the edit form" do
      get admin_attendance_record_path(record_b)
      expect(response.body).to include(I18n.t("attendance.records.save_changes"))

      original = record_b.check_in_at
      change_check_in(record_b)
      expect(response).to redirect_to(admin_attendance_record_path(record_b))
      expect(record_b.reload.check_in_at).to be < original
    end
  end

  describe "branch scope" do
    let(:branch_manager) do
      api_user_with(business, :view_attendance, :manage_attendance,
                    scopes: { "view_attendance" => "branch", "manage_attendance" => "branch" })
        .tap { |u| branch_a.update_column(:branch_manager_id, u.id) }
    end

    before { sign_in branch_manager }

    it "changes a record of their own branch" do
      original = record_a.check_in_at
      change_check_in(record_a)
      expect(response).to redirect_to(admin_attendance_record_path(record_a))
      expect(record_a.reload.check_in_at).to be < original
    end

    it "cannot change a record of another branch (404)" do
      original = record_b.check_in_at
      change_check_in(record_b)
      expect(response).to have_http_status(:not_found)
      expect(record_b.reload.check_in_at).to eq(original)
    end

    it "does not list records of another branch" do
      get admin_attendance_records_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(admin_attendance_record_path(record_a))
      expect(response.body).not_to include(admin_attendance_record_path(record_b))
    end
  end

  describe "cross-business isolation" do
    let(:foreign_record) { create(:attendance_record, :checked_out, business: other) }

    it "cannot change another business's record (404), even as the owner" do
      original = foreign_record.check_in_at
      sign_in owner
      change_check_in(foreign_record)
      expect(response).to have_http_status(:not_found)
      expect(foreign_record.reload.check_in_at).to eq(original)
    end

    it "does not list another business's records" do
      foreign_record
      sign_in owner
      get admin_attendance_records_path
      expect(response.body).not_to include(admin_attendance_record_path(foreign_record))
    end
  end
end
