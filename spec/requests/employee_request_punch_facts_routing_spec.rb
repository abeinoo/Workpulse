require "rails_helper"

# Pilot 10 — Punch Correction, M3: the web callers of
# Requests::PunchCorrectionAssessment (EmployeeRequestsController#show for the
# reviewer, #create for the out-of-window hold) read the attendance facts through
# Requests::PunchCorrectionEffects.correction_facts. Rendering itself stays
# pinned by employee_request_attendance_window_spec.rb and
# employee_request_resulting_duration_spec.rb.
RSpec.describe "Employee request punch facts routing", type: :request do
  let(:contract) { Requests::PunchCorrectionEffects }
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business, preferred_locale: "en") }
  let(:manager) do
    role = create(:permission_role, business: business, permissions: %w[view_requests approve_requests])
    create(:user, business: business, permission_role: role, preferred_locale: "en")
  end
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 13) }

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)

  let(:assignment) do
    shift = Time.use_zone(business.timezone) do
      create(:shift, :fixed_time, business: business, name: "Evening", start_time: "19:00", end_time: "02:00")
    end
    create(:shift_assignment, user: employee, branch: branch, effective_from: Date.new(2026, 1, 1), shift: shift)
  end
  let!(:record) do
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
           date: work_date, work_date: work_date,
           check_in_at: at(13, 19, 5), check_out_at: at(14, 0, 3), status: "present", worked_minutes: 298)
  end

  before do
    branch.update_column(:branch_manager_id, manager.id)
    allow(contract).to receive(:correction_facts).and_call_original
  end

  def html = Nokogiri::HTML(response.body)

  it "show (reviewer): one facts call with the request, its field, the final moment and no baseline; window rendered" do
    req = build(:employee_request, :punch_correction, :pending, user: employee, requested_for_date: work_date,
                                                                correction_type: "wrong_check_in_time",
                                                                proposed_date: work_date, proposed_time: "19:00")
    req.save!(validate: false)
    sign_in manager

    get employee_request_path(req)

    expect(response).to have_http_status(:ok)
    expect(contract).to have_received(:correction_facts).once
      .with(request: having_attributes(id: req.id), field: :check_in, effective_at: at(13, 19), baseline: nil)
    expect(html.at_css("[data-testid='window-shift']").text.squish).to include("Evening")
    expect(html.at_css("[data-testid='window-status']").text).to include(I18n.t("requests.show.window.inside", locale: :en))
  end

  it "show (requester): no facts are computed for the employee's own view" do
    req = build(:employee_request, :punch_correction, :pending, user: employee, requested_for_date: work_date,
                                                                correction_type: "wrong_check_in_time",
                                                                proposed_date: work_date, proposed_time: "19:00")
    req.save!(validate: false)
    sign_in employee

    get employee_request_path(req)

    expect(response).to have_http_status(:ok)
    expect(contract).not_to have_received(:correction_facts)
  end

  it "create: the out-of-window hold judges the proposal through the contract and saves nothing" do
    sign_in employee

    expect {
      post employee_requests_path, params: { employee_request: {
        request_type: "punch_correction", correction_type: "wrong_check_in_time", requested_for_date: work_date.iso8601,
        proposed_date: Date.new(2026, 9, 12).iso8601, proposed_time: "15:10", reason: "Forgot to punch"
      } }
    }.not_to change(EmployeeRequest, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(contract).to have_received(:correction_facts)
      .with(request: having_attributes(new_record?: true, proposed_time: "15:10"), field: :check_in,
            effective_at: at(12, 15, 10), baseline: nil)
  end
end
