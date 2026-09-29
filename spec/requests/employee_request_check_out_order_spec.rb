require "rails_helper"

# Check-out punch corrections (missing / wrong check-out) must put the
# check-out STRICTLY after the attendance record's check-in — compared as full
# datetimes, so an overnight check-out dated the next day is valid. Enforced at
# request creation, on the reviewer's final datetime, and in the applier.
RSpec.describe "Punch correction: check-out must be after check-in", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business, preferred_locale: "ar") }
  let(:manager) do
    role = create(:permission_role, business: business, permissions: %w[view_requests approve_requests])
    create(:user, business: business, permission_role: role, preferred_locale: "ar")
  end
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 12) }
  let(:message)   { I18n.t("requests.errors.check_out_not_after_check_in", locale: :ar) }

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)
  def sep(day) = Date.new(2026, 9, day)
  def html = Nokogiri::HTML(response.body)

  def assignment_for(start_time, end_time)
    shift = Time.use_zone(business.timezone) do
      create(:shift, :fixed_time, business: business, start_time: start_time, end_time: end_time)
    end
    create(:shift_assignment, user: employee, branch: branch, effective_from: Date.new(2026, 1, 1), shift: shift)
  end

  def open_record(check_in_at, assignment)
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
           date: work_date, work_date: work_date, check_in_at: check_in_at, check_out_at: nil,
           status: "incomplete", worked_minutes: nil)
  end

  def correction_params(date, time, type: "missing_check_out")
    { employee_request: { request_type: "punch_correction", correction_type: type,
                          requested_for_date: work_date.iso8601, proposed_date: date.iso8601,
                          proposed_time: time, reason: "Forgot to punch out" } }
  end

  def correction(time, date: work_date, type: "missing_check_out")
    create(:employee_request, :punch_correction, user: employee, correction_type: type,
           requested_for_date: work_date, proposed_date: date, proposed_time: time)
  end

  def approve(request, approved_at:, confirm: "1")
    sign_in manager
    patch approve_employee_request_path(request), params: { approved_at: approved_at, confirm_out_of_window: confirm }
    request.reload
  end

  before { branch.update_column(:branch_manager_id, manager.id) }

  context "day shift — checked in 12/09/2026 03:10 PM" do
    let!(:record) { open_record(at(12, 15, 10), assignment_for("15:00", "23:00")) }

    describe "employee creates the request" do
      before { sign_in employee }

      %w[missing_check_out wrong_check_out_time].each do |type|
        it "1. rejects a #{type} before the check-in (02:05 PM)" do
          expect {
            post employee_requests_path, params: correction_params(sep(12), "14:05", type: type)
          }.not_to change(EmployeeRequest, :count)

          expect(response).to have_http_status(:unprocessable_entity)
          expect(html.text).to include(message)
        end

        it "2. rejects a #{type} equal to the check-in (03:10 PM)" do
          expect {
            post employee_requests_path, params: correction_params(sep(12), "15:10", type: type)
          }.not_to change(EmployeeRequest, :count)

          expect(response).to have_http_status(:unprocessable_entity)
          expect(html.text).to include(message)
        end
      end

      it "3. accepts a check-out after the check-in (06:00 PM)" do
        expect {
          post employee_requests_path, params: correction_params(sep(12), "18:00")
        }.to change(EmployeeRequest, :count).by(1)
        expect(response).to redirect_to(employee_requests_path)
      end

      it "does not apply the rule to check-in corrections" do
        request = build(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_in_time",
                        requested_for_date: work_date, proposed_date: work_date, proposed_time: "14:05")
        expect(request).to be_valid
      end

      it "renders the recent check-ins for the live form hint" do
        travel_to(at(13, 10)) { get new_employee_request_path }
        form = html.at_css("form[data-controller='punch-order-guard']")
        expect(JSON.parse(form["data-punch-order-guard-check-ins-value"]))
          .to include("2026-09-12" => "2026-09-12T15:10")
        expect(html.at_css("[data-testid='punch-order-client-error']")["hidden"]).not_to be_nil
      end
    end

    describe "5. the reviewer cannot bypass the rule" do
      let(:request) { correction("18:00") }

      it "refuses a final datetime before the check-in, even when confirmed" do
        approve(request, approved_at: "2026-09-12T14:05")

        expect(request).to be_pending
        expect(request.approved_punch_at).to be_nil
        expect(flash[:alert]).to eq(message)
        expect(record.reload.check_out_at).to be_nil
      end

      it "refuses a final datetime equal to the check-in" do
        approve(request, approved_at: "2026-09-12T15:10")

        expect(request).to be_pending
        expect(flash[:alert]).to eq(message)
        expect(record.reload.check_out_at).to be_nil
      end

      it "refuses it through the service (API path) too" do
        result = Requests::Approver.approve(request: request, reviewed_by: manager,
                                            approved_at: at(12, 15, 10), confirm_out_of_window: true)
        expect(result).not_to be_success
        expect(result.error).to eq(I18n.t("requests.errors.check_out_not_after_check_in"))
        expect(request.reload).to be_pending
      end

      it "shows the error on the review page for the refused datetime, with the live hint wired" do
        sign_in manager
        get employee_request_path(request, approved_at: "2026-09-12T15:10")

        expect(html.at_css("[data-testid='punch-order-invalid']").text).to include(message)
        form = html.at_css("form[action$='/approve']")
        expect(form["data-controller"]).to eq("punch-order-guard")
        expect(form["data-punch-order-guard-check-in-value"]).to eq("2026-09-12T15:10")
      end

      it "approves a valid reviewer datetime after the check-in" do
        approve(request, approved_at: "2026-09-12T18:30")

        expect(request).to be_approved
        expect(record.reload.check_out_at).to eq(at(12, 18, 30))
      end
    end

    describe "6. final approval cannot save an invalid check-out" do
      it "the applier refuses a check-out equal to the check-in and leaves the record untouched" do
        request = correction("18:00")
        request.update_columns(status: "approved", reviewed_at: Time.current, approved_punch_at: at(12, 15, 10))

        result = Requests::PunchCorrectionApplier.call(request: request)

        expect(result).not_to be_success
        expect(result.error).to eq(I18n.t("requests.errors.check_out_not_after_check_in"))
        expect(record.reload.check_out_at).to be_nil
        expect(request.reload.original_check_in_at).to be_nil # snapshot rolled back
      end
    end
  end

  context "4. overnight shift — checked in 12/09/2026 07:00 PM" do
    let!(:record) { open_record(at(12, 19), assignment_for("19:00", "02:00")) }

    it "accepts a check-out at 02:00 AM on the next day at creation" do
      sign_in employee
      expect {
        post employee_requests_path, params: correction_params(sep(13), "02:00")
      }.to change(EmployeeRequest, :count).by(1)
      expect(response).to redirect_to(employee_requests_path)
    end

    it "rejects 02:00 AM on the work date (compares the full datetime, not the clock)" do
      sign_in employee
      expect {
        post employee_requests_path, params: correction_params(sep(12), "02:00")
      }.not_to change(EmployeeRequest, :count)
      expect(html.text).to include(message)
    end

    it "approves and applies the next-day check-out" do
      request = correction("02:00", date: sep(13))
      approve(request, approved_at: "2026-09-13T02:00", confirm: nil)

      expect(request).to be_approved
      expect(record.reload.check_out_at).to eq(at(13, 2))
      expect(record.worked_minutes).to eq(420)
    end
  end
end
