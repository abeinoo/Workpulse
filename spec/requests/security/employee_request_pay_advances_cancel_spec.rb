require "rails_helper"

# Pilot 9 unblock (follow-up to SEC-P9-1 / 09957e9): EmployeeRequestPolicy#cancel?
# let any pay_advances holder cancel ANY pending / approved request of the
# business — late / early-leave permissions and punch corrections included —
# ignoring the pay_advances scope, and a holder of both approve_requests and
# pay_advances could bypass the approve_requests scope through it.
#
# The pay_advances path now covers salary advance requests only
# (EmployeeRequest#salary_advance?), for employees inside the pay_advances scope
# (EmployeeScope#for_permissions(:pay_advances, :view_requests, :view_employees),
# else the manager hierarchy) or the holder's own request. Employee-owned and
# approve_requests cancellation are unchanged.
RSpec.describe "Security: pay_advances cancellation is limited to scoped salary advances", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let!(:employee_a) { create(:user, business: business) }
  let!(:employee_b) { create(:user, business: business) }

  # view_requests business-wide, so every request is found; pay_advances varies.
  def payer(scope, *extra)
    api_user_with(business, :view_requests, :pay_advances, *extra,
                  scopes: { "view_requests" => "business", "pay_advances" => scope })
  end

  let(:branch_payer) { payer("branch") }
  let(:self_payer)   { payer("self") }

  before do
    branch_a.update_column(:branch_manager_id, branch_payer.id)
    create(:shift_assignment, business: business, user: employee_a, branch: branch_a)
    create(:shift_assignment, business: business, user: employee_b, branch: branch_b)
  end

  # Business validations (advance limit, shift support, punch window) are
  # irrelevant to who may cancel; the rows are saved without them.
  def request_for(user, type, status = :approved)
    build(:employee_request, type, status, user: user, requested_for_date: Date.current - 1)
      .tap { |req| req.save!(validate: false) }
  end

  def cancel(req) = patch(cancel_employee_request_path(req), params: { cancellation_reason: "probe" })

  def expect_refused(req, status = "approved")
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
    expect(req.reload.status).to eq(status)
  end

  it "1. business scope: cancels a salary advance of any employee in the business" do
    sign_in payer("business")
    advance = request_for(employee_b, :salary_advance)

    cancel(advance)
    expect(advance.reload.status).to eq("cancelled")
  end

  describe "2. branch scope" do
    before { sign_in branch_payer }

    it "cancels a salary advance in their branch" do
      advance = request_for(employee_a, :salary_advance)
      cancel(advance)
      expect(advance.reload.status).to eq("cancelled")
    end

    it "cannot cancel a salary advance in another branch" do
      advance = request_for(employee_b, :salary_advance)
      cancel(advance)
      expect_refused(advance)
    end
  end

  describe "3. self scope" do
    before { sign_in self_payer }

    it "cancels their own salary advance (pending or approved)" do
      own_pending  = request_for(self_payer, :salary_advance, :pending)
      own_approved = request_for(self_payer, :salary_advance)

      cancel(own_pending)
      cancel(own_approved)
      expect([ own_pending.reload.status, own_approved.reload.status ]).to eq(%w[cancelled cancelled])
    end

    it "cannot cancel another employee's salary advance" do
      advance = request_for(employee_a, :salary_advance)
      cancel(advance)
      expect_refused(advance)
    end
  end

  describe "4. never a non-advance request — even same business, inside the pay_advances scope, with view_requests" do
    %i[late_permission early_leave punch_correction].each do |type|
      it "refuses to cancel an approved #{type} (business scope)" do
        sign_in payer("business")
        req = request_for(employee_a, type)
        cancel(req)
        expect_refused(req)
      end

      it "refuses to cancel a pending #{type} in their own branch (branch scope)" do
        sign_in branch_payer
        req = request_for(employee_a, type, :pending)
        cancel(req)
        expect_refused(req, "pending")
      end
    end
  end

  describe "5. employee-owned cancellation is unchanged" do
    it "an employee cancels their own pending request of any type, not their approved one" do
      sign_in employee_a
      pending_permission = request_for(employee_a, :late_permission, :pending)
      pending_advance    = request_for(employee_a, :salary_advance, :pending)
      approved_advance   = request_for(employee_a, :salary_advance)

      cancel(pending_permission)
      cancel(pending_advance)
      expect([ pending_permission.reload.status, pending_advance.reload.status ]).to eq(%w[cancelled cancelled])

      cancel(approved_advance)
      expect_refused(approved_advance)
    end
  end

  describe "6. a holder of approve_requests and pay_advances" do
    let(:dual) do
      api_user_with(business, :view_requests, :approve_requests, :pay_advances,
                    scopes: { "view_requests" => "business", "approve_requests" => "branch", "pay_advances" => "business" })
    end

    before do
      branch_a.update_column(:branch_manager_id, dual.id)
      sign_in dual
    end

    it "cannot reach another branch's permission through pay_advances (approve_requests scope governs it)" do
      req = request_for(employee_b, :late_permission)
      cancel(req)
      expect_refused(req)
    end

    it "still cancels an in-branch permission (approve_requests) and another branch's advance (pay_advances)" do
      permission = request_for(employee_a, :late_permission)
      advance    = request_for(employee_b, :salary_advance)

      cancel(permission)
      cancel(advance)
      expect([ permission.reload.status, advance.reload.status ]).to eq(%w[cancelled cancelled])
    end
  end

  it "a paid salary advance stays non-cancellable" do
    sign_in payer("business")
    paid = request_for(employee_a, :salary_advance, :approved)
    paid.update_column(:status, "paid")

    cancel(paid)
    expect_refused(paid, "paid")
  end

  # Requests that end in a rescued 404 are kept one per example.
  it "7. another business's salary advance: 404, unchanged" do
    sign_in payer("business")
    foreign = request_for(create(:user, business: other), :salary_advance)

    cancel(foreign)
    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.status).to eq("approved")
  end

  describe "8. the API cancel path gives the same answers" do
    before { sign_in branch_payer }

    def api_cancel(req) = patch(cancel_api_v1_employee_request_path(req), params: { cancellation_reason: "probe" }, as: :json)

    it "refuses another branch's advance and an in-branch permission (403), cancels an in-branch advance" do
      out_of_scope = request_for(employee_b, :salary_advance)
      permission   = request_for(employee_a, :late_permission)
      in_scope     = request_for(employee_a, :salary_advance)

      api_cancel(out_of_scope)
      expect(response).to have_http_status(:forbidden)
      api_cancel(permission)
      expect(response).to have_http_status(:forbidden)
      api_cancel(in_scope)
      expect(response).to have_http_status(:ok)

      expect([ out_of_scope, permission, in_scope ].map { |r| r.reload.status }).to eq(%w[approved approved cancelled])
    end
  end
end
