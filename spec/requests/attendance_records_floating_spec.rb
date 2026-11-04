require "rails_helper"

# Attendance pages for a record with a NULL branch: a floating employee's record
# shows "Floating" (EN / AR) wherever the branch is shown, and no page assumes a
# branch — including the location map of a record with mobile coordinates.
RSpec.describe "Attendance records — floating employee", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }
  let(:floating) { create(:shift_assignment, :floating, user: employee, shift: shift) }
  let!(:record) do
    AttendanceRecord.create!(
      user: employee, branch: nil, shift_assignment: floating,
      work_date: Date.current - 1, date: Date.current - 1,
      check_in_at: 1.day.ago.change(hour: 9), check_out_at: 1.day.ago.change(hour: 17),
      check_in_source: "mobile", check_in_latitude: 24.7, check_in_longitude: 46.6,
      status: "present"
    )
  end

  before { sign_in owner }

  {
    "the attendance record page"       => ->(r) { attendance_record_path(r) },
    "the attendance record edit page"  => ->(r) { edit_attendance_record_path(r) },
    "the admin attendance record page" => ->(r) { admin_attendance_record_path(r) }
  }.each do |page, path|
    it "renders #{page} with the Floating label" do
      get instance_exec(record, &path)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("attendance.floating_branch", locale: :en))
      expect(response.body).not_to include('data-location-map-has-branch-value="true"')
    end
  end

  it "labels the record Floating in the attendance list" do
    get attendance_records_path, params: { from: record.work_date, to: record.work_date }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("attendance.floating_branch", locale: :en))
  end

  it "uses the Arabic label" do
    owner.update!(preferred_locale: "ar")

    get attendance_record_path(record)

    expect(response.body).to include(I18n.t("attendance.floating_branch", locale: :ar))
  end

  it "shows a dash, not Floating, for another record without a branch" do
    record.update_columns(shift_assignment_id: nil)

    get admin_attendance_record_path(record)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("attendance.floating_branch", locale: :en))
  end
end
