require "rails_helper"

# SEC-P9-1 (found in Pilot 9 — Request Permission Payroll Effects, M0; Medium):
# EmployeeRequestPolicy#approve? / #reject? / #cancel? checked only the
# approve_requests flag (cancel: plus the same business), and requests are found
# through the broader view_requests scope. An approver whose approve_requests
# scope is narrower than their view_requests scope (e.g. branch vs business)
# could approve, reject or cancel requests of employees outside it — and an
# approved / cancelled late or early-leave permission changes payroll.
#
# The reviewer path now requires the request's employee to be inside the
# approver's scope resolved like request creation already does
# (approve_requests → view_requests → view_employees, else the manager
# hierarchy). Self-approval stays forbidden; an employee may still cancel their
# own pending request; an approver may still cancel their own approved one; the
# pay_advances cancel path is unchanged (product decision, see the commit).
RSpec.describe "Security: approve_requests scope on approve / reject / cancel", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let!(:employee_a) { create(:user, business: business) }
  let!(:employee_b) { create(:user, business: business) }

  # view_requests is business-wide, so every request is found; approve_requests varies.
  def approver(scope)
    api_user_with(business, :view_requests, :approve_requests,
                  scopes: { "view_requests" => "business", "approve_requests" => scope })
  end

  let(:branch_approver) { approver("branch") }
  let(:self_approver)   { approver("self") }

  before do
    branch_a.update_column(:branch_manager_id, branch_approver.id)
    create(:shift_assignment, business: business, user: employee_a, branch: branch_a)
    create(:shift_assignment, business: business, user: employee_b, branch: branch_b)
  end

  def permission_request(user, status = :pending)
    create(:employee_request, :late_permission, status, user: user, requested_for_date: Date.current - 1)
  end

  def approve(req) = patch(approve_employee_request_path(req))
  def reject(req)  = patch(reject_employee_request_path(req))
  def cancel(req)  = patch(cancel_employee_request_path(req), params: { cancellation_reason: "probe" })

  def expect_refused
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "branch scope: outside the branch is refused, nothing changes" do
    before { sign_in branch_approver }

    it "1. cannot approve another branch's request" do
      req = permission_request(employee_b)
      approve(req)
      expect_refused
      expect(req.reload.status).to eq("pending")
    end

    it "2. cannot reject another branch's request" do
      req = permission_request(employee_b)
      reject(req)
      expect_refused
      expect(req.reload.status).to eq("pending")
    end

    it "3. cannot cancel another branch's approved request" do
      req = permission_request(employee_b, :approved)
      cancel(req)
      expect_refused
      expect(req.reload.status).to eq("approved")
    end
  end

  describe "branch scope: inside the branch still works" do
    before { sign_in branch_approver }

    it "4. approves an in-branch request" do
      req = permission_request(employee_a)
      approve(req)
      expect(req.reload.status).to eq("approved")
    end

    it "5. rejects an in-branch request" do
      req = permission_request(employee_a)
      reject(req)
      expect(req.reload.status).to eq("rejected")
    end

    it "6. cancels an in-branch approved request" do
      req = permission_request(employee_a, :approved)
      cancel(req)
      expect(req.reload.status).to eq("cancelled")
    end
  end

  describe "self scope" do
    before { sign_in self_approver }

    it "7. cannot approve, reject or cancel another employee's request" do
      pending_req  = permission_request(employee_a)
      approved_req = permission_request(employee_a, :approved)

      approve(pending_req)
      expect_refused
      reject(pending_req)
      expect_refused
      cancel(approved_req)
      expect_refused
      expect([ pending_req.reload.status, approved_req.reload.status ]).to eq(%w[pending approved])
    end

    it "8. on their own requests: no self-approval or self-rejection; cancelling their own pending or approved request stays allowed" do
      own_pending  = permission_request(self_approver)
      own_approved = permission_request(self_approver, :approved)

      approve(own_pending)
      expect_refused
      reject(own_pending)
      expect_refused
      expect(own_pending.reload.status).to eq("pending")

      cancel(own_pending)
      expect(own_pending.reload.status).to eq("cancelled")
      cancel(own_approved)
      expect(own_approved.reload.status).to eq("cancelled")
    end
  end

  it "9. business scope: approves, rejects and cancels for any employee of the business" do
    sign_in approver("business")
    to_approve, to_reject = permission_request(employee_b), permission_request(employee_a)
    to_cancel = permission_request(employee_b, :approved)

    approve(to_approve)
    reject(to_reject)
    cancel(to_cancel)

    expect([ to_approve, to_reject, to_cancel ].map { |r| r.reload.status }).to eq(%w[approved rejected cancelled])
  end

  it "the owner keeps full access" do
    sign_in create(:user, :owner, business: business)
    req = permission_request(employee_b)
    approve(req)
    expect(req.reload.status).to eq("approved")
  end

  # Requests that end in a rescued 404 are kept one per example.
  it "10. another business's request: 404, unchanged" do
    sign_in approver("business")
    foreign = permission_request(create(:user, business: other))
    approve(foreign)
    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.status).to eq("pending")
  end

  describe "the API path follows the same policy" do
    before { sign_in branch_approver }

    it "approve / reject / cancel another branch's request: 403, unchanged" do
      pending_req  = permission_request(employee_b)
      approved_req = permission_request(employee_b, :approved)

      patch approve_api_v1_employee_request_path(pending_req), as: :json
      expect(response).to have_http_status(:forbidden)
      patch reject_api_v1_employee_request_path(pending_req), as: :json
      expect(response).to have_http_status(:forbidden)
      patch cancel_api_v1_employee_request_path(approved_req), params: { cancellation_reason: "probe" }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect([ pending_req.reload.status, approved_req.reload.status ]).to eq(%w[pending approved])
    end

    it "approves an in-branch request" do
      req = permission_request(employee_a)
      patch approve_api_v1_employee_request_path(req), as: :json
      expect(response).to have_http_status(:ok)
      expect(req.reload.status).to eq("approved")
    end
  end
end
