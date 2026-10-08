require "rails_helper"

# SEC-P10-1 (found in Pilot 10 — Punch Correction, M0; Medium): an approver could
# create a request ON BEHALF of an employee and then approve it themselves —
# the self-approval rule compared the approver only with the employee the
# request is for (user_id), requests recorded no submitter, and creation was
# not audited. For a punch correction that rewrote another employee's
# attendance and pay with no second reviewer.
#
# Every request now records its submitter (employee_requests.submitted_by_id,
# set by Requests::Submitter from the signed-in user, never from params), the
# creation is audited, and neither the employee nor the submitter may approve
# or reject it.
RSpec.describe "Security: request submitter and self-approval", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let!(:employee) { create(:user, business: business) }

  def approver(scope = "business")
    api_user_with(business, :view_requests, :approve_requests, :view_employees,
                  scopes: { "view_requests" => scope, "approve_requests" => scope, "view_employees" => scope })
  end

  let(:approver_a) { approver }
  let(:approver_b) { approver }

  before { create(:shift_assignment, business: business, user: employee, branch: branch_a) }

  def submit(as:, for_user: nil, extra: {})
    sign_in as
    post employee_requests_path, params: { for_user_id: for_user&.id,
                                           employee_request: { request_type: "late_permission", duration_minutes: 30,
                                                               requested_for_date: Date.current + 1, reason: "doctor" }.merge(extra) }
    EmployeeRequest.where(user: for_user || as).order(:id).last
  end

  def expect_refused
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "submitter tracking and creation audit" do
    it "a request created by the employee for themselves: submitted_by == user, audited as theirs" do
      req = submit(as: employee)

      expect(req).to have_attributes(user_id: employee.id, submitted_by_id: employee.id)
      log = AuditLog.find_by(auditable: req, action: "create")
      expect(log).to have_attributes(actor_id: employee.id)
      expect(log.metadata).to include("request_type" => "late_permission", "for_user_id" => employee.id,
                                      "submitted_by_id" => employee.id, "on_behalf" => false)
    end

    it "a request created on behalf: submitted_by is the approver, the audit names both" do
      req = submit(as: approver_a, for_user: employee)

      expect(req).to have_attributes(user_id: employee.id, submitted_by_id: approver_a.id)
      expect(AuditLog.find_by(auditable: req, action: "create").metadata)
        .to include("for_user_id" => employee.id, "submitted_by_id" => approver_a.id, "on_behalf" => true)
    end

    it "submitted_by_id cannot be mass-assigned" do
      req = submit(as: employee, extra: { submitted_by_id: approver_a.id })
      expect(req.submitted_by_id).to eq(employee.id)
    end

    it "the API path records the submitter and audits too" do
      sign_in employee
      post api_v1_employee_requests_path, params: { employee_request: { request_type: "late_permission", duration_minutes: 30,
                                                                         requested_for_date: Date.current + 1, reason: "x",
                                                                         submitted_by_id: approver_a.id } }, as: :json
      req = EmployeeRequest.where(user: employee).last

      expect(response).to have_http_status(:created)
      expect(req.submitted_by_id).to eq(employee.id)
      expect(AuditLog.where(auditable: req, action: "create").pluck(:actor_id)).to eq([ employee.id ])
    end
  end

  describe "self-approval" do
    it "1–2. employee's own request: the employee cannot approve it, another authorized approver can" do
      req = submit(as: employee)

      sign_in employee
      patch approve_employee_request_path(req)
      expect_refused

      sign_in approver_b
      patch approve_employee_request_path(req)
      expect(req.reload.status).to eq("approved")
    end

    it "3. an approver cannot approve — or reject — a request they submitted on behalf of an employee" do
      req = submit(as: approver_a, for_user: employee)

      patch approve_employee_request_path(req)
      expect_refused
      patch reject_employee_request_path(req)
      expect_refused
      expect(req.reload.status).to eq("pending")
    end

    it "3. the service refuses it too (backstop for direct calls)" do
      req = submit(as: approver_a, for_user: employee)
      result = Requests::Approver.approve(request: req, reviewed_by: approver_a)

      expect(result).not_to be_success
      expect(result.error).to eq(Approvals::SelfApproval.error_message)
      expect(req.reload.status).to eq("pending")
    end

    it "4. another authorized approver can approve the on-behalf request" do
      req = submit(as: approver_a, for_user: employee)

      sign_in approver_b
      patch approve_employee_request_path(req)
      expect(req.reload).to have_attributes(status: "approved", reviewed_by_id: approver_b.id)
    end

    it "a legacy request without a recorded submitter keeps the employee-only rule" do
      req = submit(as: approver_a, for_user: employee)
      req.update_column(:submitted_by_id, nil)

      sign_in approver_a
      patch approve_employee_request_path(req)
      expect(req.reload.status).to eq("approved")
    end
  end

  describe "scopes stay intact" do
    it "5. an approver whose branch scope excludes the employee cannot approve" do
      req = submit(as: employee)
      outsider = api_user_with(business, :view_requests, :approve_requests,
                               scopes: { "view_requests" => "business", "approve_requests" => "branch" })
      branch_b.update_column(:branch_manager_id, outsider.id)

      sign_in outsider
      patch approve_employee_request_path(req)
      expect_refused
      expect(req.reload.status).to eq("pending")
    end

    it "6. another business's approver gets 404" do
      req = submit(as: employee)
      foreign = api_user_with(other, :view_requests, :approve_requests,
                              scopes: { "view_requests" => "business", "approve_requests" => "business" })

      sign_in foreign
      patch approve_employee_request_path(req)
      expect(response).to have_http_status(:not_found)
      expect(req.reload.status).to eq("pending")
    end
  end
end
