require "rails_helper"

# A salary advance is checked against a limit derived from the employee's
# salary — for a monthly salary a fixed percentage of it, so the salary can be
# read off it (50% of 6,420.00 → 3,210.00) — and whether a request is accepted
# reveals that limit. Decisions of 2026-10-19:
# * on another employee's behalf, a salary advance may be submitted only by an
#   actor who may view that employee's salary (view_payroll inside its scope);
#   anyone else is refused BEFORE any limit is computed, with the same neutral
#   response whatever the amount and whether or not a salary profile exists;
# * the form offers the advance, and shows the limit (an audited salary view),
#   only to such an actor;
# * an employee's own advance requests are unchanged.
RSpec.describe "Advance limit disclosure", type: :request do
  let(:business) { create(:business, max_salary_advance_percentage: 50) }
  let(:branch_a) { create(:branch, business: business) }
  let(:employee) { create(:user, business: business).tap { |u| assign(u, branch_a) } }
  let!(:profile) { create(:salary_profile, :monthly, user: employee, base_amount: 6420) }
  let(:no_profile_employee) { create(:user, business: business).tap { |u| assign(u, branch_a) } }

  def assign(user, branch)
    create(:shift_assignment, business: business, user: user, branch: branch,
                              effective_from: 1.month.ago.to_date, effective_to: nil)
  end

  APPROVER_SCOPES = { "view_requests" => "business", "approve_requests" => "business", "view_employees" => "business" }.freeze

  def approver(*extra, scopes: {})
    api_user_with(business, :view_requests, :approve_requests, :view_employees, *extra, scopes: APPROVER_SCOPES.merge(scopes))
  end

  # May view the employee's salary: view_payroll, business scope.
  def payroll_approver = approver(:view_payroll, scopes: { "view_payroll" => "business" })

  # view_payroll, but its (hierarchy-default) scope is another branch.
  def outside_payroll_approver
    approver(:view_payroll).tap { |u| create(:branch, business: business).update_column(:branch_manager_id, u.id) }
  end

  def salary_views = AuditLog.where(action: "view_salary")
  def advances_for(user) = EmployeeRequest.where(user: user, request_type: "salary_advance")

  def open_form_for(user)
    get new_employee_request_path(for_user_id: user.id)
    expect(response).to have_http_status(:ok)
  end

  def submit_advance(for_user:, amount:)
    post employee_requests_path, params: {
      for_user_id: for_user.id,
      employee_request: { request_type: "salary_advance", amount: amount, requested_for_date: Date.current, reason: "rent" }
    }
  end

  def advance_option?(body) = Nokogiri::HTML(body).css("#request_type_select option[value='salary_advance']").any?

  # Everything an unauthorized submitter learns from one attempt.
  def refusal_signature
    [ response.status, response.location, flash[:alert] ]
  end

  describe "the employee's own advance (unchanged)" do
    before { sign_in employee }

    it "is offered with the limit, submitted within it, refused above it with the remaining amount" do
      expect { get new_employee_request_path }.not_to change(salary_views, :count)
      expect(response.body).to include("3,210.00")
      expect(advance_option?(response.body)).to be(true)

      post employee_requests_path, params: { employee_request: { request_type: "salary_advance", amount: 3000,
                                                                 requested_for_date: Date.current, reason: "rent" } }
      expect(advances_for(employee).count).to eq(1)

      post employee_requests_path, params: { employee_request: { request_type: "salary_advance", amount: 5000,
                                                                 requested_for_date: Date.current, reason: "rent" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("210") # the employee's own remaining amount (3,210 − 3,000)
    end

    it "keeps the employee's own no-profile message" do
      sign_in no_profile_employee
      get new_employee_request_path
      expect(response.body).to include(CGI.escapeHTML(I18n.t("requests.new.advance_no_salary_profile")))
    end

    it "is created through the API for the signed-in employee only (no on-behalf path)" do
      expect do
        post "/api/v1/employee_requests", params: { for_user_id: no_profile_employee.id, user_id: no_profile_employee.id,
                                                    employee_request: { request_type: "salary_advance", amount: 100,
                                                                        requested_for_date: Date.current, reason: "rent" } }, as: :json
      end.not_to change { advances_for(no_profile_employee).count }
      expect(advances_for(employee).count).to eq(1)
    end
  end

  describe "an approver who may view the employee's salary" do
    it "is offered the advance and the limit, as an audited salary view" do
      sign_in payroll_approver
      expect { open_form_for(employee) }.to change(salary_views, :count).by(1)

      expect(advance_option?(response.body)).to be(true)
      expect(response.body).to include("3,210.00")
      expect(salary_views.last.metadata).to eq("source" => "request_advance_limit", "self_view" => false,
                                                "salary_profile_ids" => [ profile.id ])
      expect(salary_views.last.to_json).not_to include("3210.0", "6420.0") # decimals: ids may contain the bare digits
    end

    it "submits within the limit; above it gets the generic on-behalf error" do
      sign_in payroll_approver
      expect { submit_advance(for_user: employee, amount: 3000) }.to change { advances_for(employee).count }.by(1)

      expect { submit_advance(for_user: employee, amount: 5000) }.not_to change(EmployeeRequest, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(CGI.escapeHTML(I18n.t("requests.errors.exceeds_advance_limit_on_behalf")))
    end

    it "as a branch manager (hierarchy-default scope) for an employee of their branch" do
      manager = approver(:view_payroll).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }
      sign_in manager
      expect { submit_advance(for_user: employee, amount: 3000) }.to change { advances_for(employee).count }.by(1)
    end

    it "leaves approval to another approver, which still works" do
      submitter = payroll_approver
      sign_in submitter
      submit_advance(for_user: employee, amount: 3000)
      request = advances_for(employee).sole
      expect(request.submitted_by).to eq(submitter)

      sign_in approver
      patch approve_employee_request_path(request)
      expect(request.reload).to be_approved
    end
  end

  # Refused before any limit is computed: one neutral response for every amount,
  # with or without a salary profile — nothing to probe.
  shared_examples "refused without disclosing the limit" do
    it "is not offered the advance, nor shown the limit or the profile's absence" do
      expect { open_form_for(employee) }.not_to change(salary_views, :count)
      expect(advance_option?(response.body)).to be(false)
      expect(response.body).not_to include("3,210.00", "6,420.00")

      open_form_for(no_profile_employee)
      expect(advance_option?(response.body)).to be(false)
      expect(response.body).not_to include(CGI.escapeHTML(I18n.t("requests.new.advance_no_salary_profile")))
    end

    it "is refused identically for every amount and whether or not a profile exists — nothing is created" do
      expect(Salary::AdvanceEligibilityCalculator).not_to receive(:for)

      signatures = [ [ employee, 100 ], [ employee, 3_000 ], [ employee, 3_211 ], [ employee, 99_999 ],
                     [ no_profile_employee, 100 ] ].map do |target, amount|
        expect { submit_advance(for_user: target, amount: amount) }.not_to change(EmployeeRequest, :count)
        expect(response).to redirect_to(root_path)
        expect(response.body).not_to include("3210", "3,210", "6420", "6,420")
        refusal_signature
      end

      expect(signatures.uniq).to eq([ [ 302, "http://www.example.com/", I18n.t("flash.not_authorized") ] ])
    end
  end

  context "an approver without view_payroll" do
    before { sign_in approver }

    it_behaves_like "refused without disclosing the limit"
  end

  context "an approver with view_payroll outside the employee's scope" do
    before { sign_in outside_payroll_approver }

    it_behaves_like "refused without disclosing the limit"
  end

  it "still lets an approver without view_payroll submit other request types on behalf" do
    sign_in approver
    expect do
      post employee_requests_path, params: { for_user_id: employee.id,
                                             employee_request: { request_type: "late_permission", duration_minutes: 30,
                                                                 requested_for_date: Date.current + 1, reason: "doctor" } }
    end.to change { EmployeeRequest.where(user: employee, request_type: "late_permission").count }.by(1)
  end
end
