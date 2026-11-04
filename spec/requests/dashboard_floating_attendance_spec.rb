require "rails_helper"

# The employee dashboard's check-out form for an open attendance record with no
# branch — a floating employee's record (branch_id NULL; each punch keeps its
# actual branch on its log). The form must render without a branch, must not
# require geolocation, and checking out through it must leave the record
# branch-less. A branch-backed record keeps its branch's geolocation rule.
RSpec.describe "Dashboard — check-out for a record without a branch", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:zone)     { business.timezone_object }
  let(:shift)    { create(:shift, :hour_based, business: business) }

  # Midday business-local time, so the work date is the same whenever the suite runs.
  around { |example| travel_to(Time.find_zone("Asia/Riyadh").local(2026, 11, 4, 12)) { example.run } }

  def today = BusinessDay.current(context: business)

  def open_record(user:, assignment:, branch:)
    create(:attendance_record, user: user, branch: branch, shift_assignment: assignment,
                               date: today, work_date: today,
                               check_in_at: zone.local(today.year, today.month, today.day, 9),
                               check_in_source: "biometric_device", status: "incomplete")
  end

  def check_out_form
    Nokogiri::HTML(response.body).at_css("form[action='#{attendance_check_out_path}']")
  end

  describe "a floating employee with an open, branch-less record" do
    let(:employee)    { create(:user, business: business, allow_mobile_attendance: true) }
    let(:assignment)  { create(:shift_assignment, :floating, user: employee, shift: shift, effective_from: Date.new(2026, 10, 1)) }
    let!(:record)     { open_record(user: employee, assignment: assignment, branch: nil) }

    before { sign_in employee }

    it "renders the dashboard with a check-out form that requires no geolocation and carries no branch" do
      get root_path

      expect(response).to have_http_status(:ok)
      form = check_out_form
      expect(form).to be_present
      expect(form["data-attendance-location-required-value"]).to eq("false")
      expect(form.at_css("input[name='branch_id']")["value"].to_s).to eq("")
    end

    it "checks out through the existing web flow and keeps the record branch-less" do
      post attendance_check_out_path, params: { branch_id: "", latitude: "", longitude: "" }

      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to be_present
      expect(record.reload).to have_attributes(branch_id: nil, shift_assignment_id: assignment.id)
      expect(record.check_out_at).to be_present
    end
  end

  describe "an ordinary employee with a branch-backed record" do
    let(:branch) do
      create(:branch, business: business, geolocation_enabled: true, latitude: 24.7136, longitude: 46.6753, radius_meters: 100)
    end
    let(:employee)   { create(:user, business: business, allow_mobile_attendance: true) }
    let(:assignment) { create(:shift_assignment, user: employee, shift: shift, branch: branch, effective_from: Date.new(2026, 10, 1)) }
    let!(:record)    { open_record(user: employee, assignment: assignment, branch: branch) }

    before { sign_in employee }

    it "keeps requiring geolocation and posting the record's branch" do
      get root_path

      expect(response).to have_http_status(:ok)
      form = check_out_form
      expect(form["data-attendance-location-required-value"]).to eq("true")
      expect(form.at_css("input[name='branch_id']")["value"]).to eq(branch.id.to_s)
    end

    it "still refuses a check-out without coordinates inside the geofence" do
      post attendance_check_out_path, params: { branch_id: branch.id }

      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to be_present
      expect(record.reload.check_out_at).to be_nil
    end
  end
end
