require "rails_helper"

# Pilot report (Oct 2026): a Branch Manager holding approve_requests "could not
# approve fingerprint (punch) corrections". Punch corrections were never
# excluded from approve_requests — the blocked requests were ones the manager
# had SUBMITTED on the employee's behalf, which SEC-P10-1 deliberately refuses.
# The dashboard still showed Approve/Reject on them (no policy check), so the
# click was refused. These specs pin the real rule end to end: a branch-scoped
# approver reviews their branch's punch corrections; scope, status and the
# submitter rule hold; the dashboard offers only what the policy allows.
RSpec.describe "Branch Manager reviews punch corrections", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:riyadh)   { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.current - 1 }

  let(:employee_a) { create(:user, business: business) }
  let(:employee_b) { create(:user, business: business) }

  # Mirrors the production "مدير فرع" role: branch-scoped request permissions.
  let(:branch_manager) do
    api_user_with(business, :view_requests, :approve_requests, :view_employees, :view_attendance,
                  scopes: { "view_requests" => "branch", "approve_requests" => "branch",
                            "view_employees" => "branch", "view_attendance" => "branch" })
  end
  let(:area_manager) do
    api_user_with(business, :view_requests, :approve_requests, :view_employees,
                  scopes: { "view_requests" => "business", "approve_requests" => "business",
                            "view_employees" => "business" })
  end

  let(:shift) { Time.use_zone(business.timezone) { create(:shift, :fixed_time, business: business) } }

  def at_work(hour, min = 0) = riyadh.local(work_date.year, work_date.month, work_date.day, hour, min)

  # Checked in on time, forgot to check out — the typical fingerprint correction.
  def attendance_for(employee, branch)
    assignment = create(:shift_assignment, business: business, user: employee, branch: branch, shift: shift,
                                           effective_from: work_date - 30)
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                               date: work_date, work_date: work_date, check_in_at: at_work(9), check_out_at: nil,
                               status: "incomplete")
  end

  let!(:record_a) { attendance_for(employee_a, branch_a) }
  let!(:record_b) { attendance_for(employee_b, branch_b) }

  before do
    branch_a.update_column(:branch_manager_id, branch_manager.id)
  end

  def correction_for(employee, **attrs)
    create(:employee_request, :punch_correction, user: employee, requested_for_date: work_date,
                                                 proposed_date: work_date, proposed_time: "17:00", **attrs)
  end

  let(:request_a) { correction_for(employee_a) }
  let(:request_b) { correction_for(employee_b) }

  def expect_refused
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "policy" do
    it "allows approve/reject for an own-branch punch correction and denies an out-of-branch one" do
      own_branch   = EmployeeRequestPolicy.new(branch_manager, request_a)
      other_branch = EmployeeRequestPolicy.new(branch_manager, request_b)
      expect([ own_branch.approve?, own_branch.reject?, own_branch.review_details? ]).to all(be true)
      expect([ other_branch.approve?, other_branch.reject? ]).to all(be false)
    end

    it "denies a user who can view requests but lacks approve_requests" do
      viewer = api_user_with(business, :view_requests, scopes: { "view_requests" => "business" })
      policy = EmployeeRequestPolicy.new(viewer, request_a)
      expect([ policy.approve?, policy.reject? ]).to all(be false)
    end
  end

  describe "1. approve" do
    it "approves an own-branch punch correction and applies it to attendance" do
      sign_in branch_manager
      patch approve_employee_request_path(request_a)

      expect(request_a.reload).to have_attributes(status: "approved", reviewed_by_id: branch_manager.id)
      expect(record_a.reload.check_out_at).to eq(at_work(17))
      expect(AuditLog.where(auditable: request_a, action: "approve", actor_id: branch_manager.id)).to exist
    end
  end

  describe "2. reject" do
    it "rejects an own-branch punch correction with a reason, leaving attendance untouched" do
      sign_in branch_manager
      patch reject_employee_request_path(request_a), params: { response_note: "No evidence" }

      expect(request_a.reload).to have_attributes(status: "rejected", reviewed_by_id: branch_manager.id,
                                                  response_note: "No evidence")
      expect(record_a.reload.check_out_at).to be_nil
    end
  end

  describe "3–4. branch scope" do
    it "3. sees and can open their own branch's punch correction" do
      sign_in branch_manager
      get employee_request_path(request_a)
      expect(response).to have_http_status(:ok)
    end

    it "4. cannot see, approve or reject a punch correction outside their branch" do
      sign_in branch_manager

      patch approve_employee_request_path(request_b)
      expect(response).to have_http_status(:not_found)
      sign_in branch_manager # a 404 does not persist the test session
      patch reject_employee_request_path(request_b), params: { response_note: "x" }
      expect(response).to have_http_status(:not_found)

      expect(request_b.reload.status).to eq("pending")
      expect(record_b.reload.check_out_at).to be_nil
    end
  end

  describe "5. without approve_requests" do
    it "cannot approve or reject even inside the branch" do
      viewer = api_user_with(business, :view_requests, scopes: { "view_requests" => "branch" })
      branch_a.update_column(:branch_manager_id, viewer.id)

      sign_in viewer
      patch approve_employee_request_path(request_a)
      expect_refused
      patch reject_employee_request_path(request_a), params: { response_note: "x" }
      expect_refused
      expect(request_a.reload.status).to eq("pending")
    end
  end

  describe "6–7. status guard (backend, regardless of UI)" do
    it "6. an approved punch correction cannot be approved or rejected again" do
      Requests::Approver.approve(request: request_a, reviewed_by: area_manager)
      applied_at = record_a.reload.check_out_at

      sign_in branch_manager
      patch approve_employee_request_path(request_a), params: { approved_at: "#{work_date.iso8601}T18:00" }
      expect(flash[:alert]).to eq("Request is already approved")
      patch reject_employee_request_path(request_a), params: { response_note: "x" }
      expect(flash[:alert]).to eq("Request is already approved")

      expect(request_a.reload).to have_attributes(status: "approved", reviewed_by_id: area_manager.id)
      expect(record_a.reload.check_out_at).to eq(applied_at)
    end

    it "7. a rejected punch correction cannot be approved or rejected again" do
      Requests::Approver.reject(request: request_a, reviewed_by: area_manager, response_note: "no")

      sign_in branch_manager
      patch approve_employee_request_path(request_a)
      expect(flash[:alert]).to eq("Request is already rejected")
      patch reject_employee_request_path(request_a), params: { response_note: "x" }
      expect(flash[:alert]).to eq("Request is already rejected")

      expect(request_a.reload).to have_attributes(status: "rejected", reviewed_by_id: area_manager.id)
      expect(record_a.reload.check_out_at).to be_nil
    end

    it "a cancelled punch correction cannot be approved" do
      request_a.update_column(:status, "cancelled")

      sign_in branch_manager
      patch approve_employee_request_path(request_a)
      expect(flash[:alert]).to eq("Request is already cancelled")
      expect(request_a.reload.status).to eq("cancelled")
    end
  end

  describe "8–9. existing behaviour unchanged" do
    it "8. a punch correction the manager submitted on the employee's behalf stays refused (SEC-P10-1)" do
      on_behalf = correction_for(employee_a, submitted_by: branch_manager)

      sign_in branch_manager
      patch approve_employee_request_path(on_behalf)
      expect_refused
      patch reject_employee_request_path(on_behalf), params: { response_note: "x" }
      expect_refused
      expect(on_behalf.reload.status).to eq("pending")

      sign_in area_manager
      patch approve_employee_request_path(on_behalf)
      expect(on_behalf.reload).to have_attributes(status: "approved", reviewed_by_id: area_manager.id)
    end

    it "9. the same Branch Manager still approves other request types in their branch" do
      early_leave = create(:employee_request, user: employee_a, request_type: "early_leave",
                                              requested_for_date: Date.current + 1, duration_minutes: 30)

      sign_in branch_manager
      patch approve_employee_request_path(early_leave)
      expect(early_leave.reload).to have_attributes(status: "approved", reviewed_by_id: branch_manager.id)
    end
  end

  describe "request page" do
    def page_for(request)
      sign_in branch_manager
      get employee_request_path(request)
      Nokogiri::HTML(response.body)
    end

    it "shows the review form and reject action on an own-branch pending punch correction" do
      doc = page_for(request_a)
      expect(doc.at_css("form[action$='/approve']")).to be_present
      expect(doc.at_css("form[action$='/reject']")).to be_present
      expect(doc.at_css("[data-testid='awaiting-other-reviewer']")).to be_nil
    end

    it "explains — instead of offering actions — when the manager submitted it on the employee's behalf" do
      doc = page_for(correction_for(employee_a, submitted_by: branch_manager))
      expect(doc.at_css("form[action$='/approve']")).to be_nil
      expect(doc.at_css("form[action$='/reject']")).to be_nil
      expect(doc.at_css("[data-testid='awaiting-other-reviewer']").text)
        .to include(I18n.t("requests.show.awaiting_other_reviewer"))
    end

    it "offers no actions once the punch correction is approved" do
      Requests::Approver.approve(request: request_a, reviewed_by: area_manager)
      doc = page_for(request_a)
      expect(doc.at_css("form[action$='/approve']")).to be_nil
      expect(doc.at_css("form[action$='/reject']")).to be_nil
    end
  end

  describe "dashboard pending requests (uses the same policy as the controller)" do
    def dashboard
      sign_in branch_manager
      get root_path
      Nokogiri::HTML(response.body)
    end

    def approve_forms(doc, request) = doc.css("form[action='#{approve_employee_request_path(request)}']")
    def reject_forms(doc, request)  = doc.css("form[action='#{reject_employee_request_path(request)}']")

    it "links an own-branch punch correction to its review page instead of one-click approval" do
      request_a
      doc = dashboard

      expect(approve_forms(doc, request_a)).to be_empty
      expect(doc.css("a[href='#{employee_request_path(request_a)}']").map(&:text).map(&:strip))
        .to include(I18n.t("requests.show.review_correction"))
    end

    it "offers no Approve/Reject on a request the manager submitted, and says why" do
      on_behalf = correction_for(employee_a, submitted_by: branch_manager)
      doc = dashboard

      expect(approve_forms(doc, on_behalf)).to be_empty
      expect(reject_forms(doc, on_behalf)).to be_empty
      expect(doc.css("[data-testid='awaiting-other-reviewer']").map(&:text))
        .to include(I18n.t("requests.awaiting_other_reviewer"))
    end

    it "keeps one-click Approve/Reject for other approvable request types" do
      early_leave = create(:employee_request, user: employee_a, request_type: "early_leave",
                                              requested_for_date: Date.current + 1, duration_minutes: 30)
      doc = dashboard

      expect(approve_forms(doc, early_leave)).not_to be_empty
      expect(reject_forms(doc, early_leave)).not_to be_empty
    end
  end
end
