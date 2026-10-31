require "rails_helper"

# Characterization (Batch V — Workforce → Attendance & Payroll request-validation
# reads, D-A5; M1) — the CURRENT behaviour of the seven sites where Workforce
# request code reads Attendance & Payroll today, pinned against unchanged code
# before any of them moves behind a Workforce-defined contract
# (docs/architecture/workforce-request-validation-reads-baseline-failures.txt):
#
#   1. EmployeeRequest#within_advance_limit — the advance-limit validation
#   2. EmployeeRequestsController#advance_limit_for — the form's limit hint, the
#      on-behalf salary visibility decision and the salary-view audit
#   3. EmployeeRequestsController#show — the attendance record of the request date
#   4. EmployeeRequestsController#punch_check_ins_for — the form's check-in hint
#   5. EmployeeRequestPolicy#create? — on-behalf salary advances
#   6. show.html.erb — the duration alert's threshold
#   7. _resulting_duration.html.erb — the punch-correction panel's threshold
#
# Rendered fragments are compared byte-for-byte with the strings recorded here
# from the unchanged code; never re-record them to absorb a difference.
module RequestValidationReadsCharacterization
  APPROVER_SCOPES = { "view_requests" => "business", "approve_requests" => "business", "view_employees" => "business" }.freeze

  # Recorded from the unchanged code on bc6682b (2026-10-21).
  RECORDED = {
    api_no_profile: [ 422, { "success" => false, "message" => "Failed to submit request", "errors" => [ "Amount cannot be requested because no salary profile is configured for this employee" ] } ],
    api_over_limit: [ 422, { "success" => false, "message" => "Failed to submit request", "errors" => [ "Amount exceeds your available advance limit (210.0 SAR remaining)" ] } ],
    check_ins_empty: "data-punch-order-guard-check-ins-value=\"{}\"",
    check_ins_own: "data-punch-order-guard-check-ins-value=\"{&quot;2026-09-19&quot;:&quot;2026-09-19T08:05&quot;,&quot;2026-07-20&quot;:&quot;2026-07-20T07:59&quot;,&quot;2026-09-18&quot;:&quot;2026-09-17T23:30&quot;}\"",
    duration_alert_critical: "<div class=\"alert alert-danger window-alert\"\n         role=\"alert\" data-testid=\"duration-alert\">\n      <p class=\"window-alert__title\">⚠️ Abnormal work duration: 15h 0m</p>\n      <p>Exceeds 14 hours — this duration requires review. The attendance record has not been changed.</p>\n    </div>",
    duration_alert_suspicious: "<div class=\"alert alert-warning window-alert\"\n         role=\"alert\" data-testid=\"duration-alert\">\n      <p class=\"window-alert__title\">⚠️ Abnormal work duration: 11h 0m</p>\n      <p>Exceeds 10 hours — this duration requires review. The attendance record has not been changed.</p>\n    </div>",
    hint_on_behalf_422: "<p class=\"form-hint form-hint--advance\" id=\"advance-limit-hint\">\n            Max advance: 50.0% of your monthly salary (3,210.00 SAR).\n            <br>\n            <strong>\n              Available: 3,210.00 SAR\n            </strong>\n          </p>",
    hint_on_behalf_hidden: "<p class=\"form-hint\" id=\"advance-limit-hint\">The advance limit for this employee is checked when the request is submitted.</p>",
    hint_on_behalf_no_profile: "<p class=\"form-hint form-hint--warning\" id=\"advance-limit-hint\">\n            No salary profile is configured for this employee, so a salary advance cannot be calculated. Contact an administrator to set one up.\n          </p>",
    hint_on_behalf_visible: "<p class=\"form-hint form-hint--advance\" id=\"advance-limit-hint\">\n            Max advance: 50.0% of your monthly salary (3,210.00 SAR).\n            <br>\n            <strong>\n              Available: 3,210.00 SAR\n            </strong>\n          </p>",
    hint_own: "<p class=\"form-hint form-hint--advance\" id=\"advance-limit-hint\">\n            Max advance: 50.0% of your monthly salary (3,210.00 SAR).\n            <br>\n            <strong>\n              Available: 3,210.00 SAR\n            </strong>\n          </p>",
    hint_own_422: "<p class=\"form-hint form-hint--advance\" id=\"advance-limit-hint\">\n            Max advance: 50.0% of your monthly salary (3,210.00 SAR).\n            <br>\n            <strong>\n              Available: 3,210.00 SAR\n            </strong>\n          </p>",
    hint_own_no_profile: "<p class=\"form-hint form-hint--warning\" id=\"advance-limit-hint\">\n            No salary profile is configured for this employee, so a salary advance cannot be calculated. Contact an administrator to set one up.\n          </p>",
    hint_own_outstanding: "<p class=\"form-hint form-hint--advance\" id=\"advance-limit-hint\">\n            Max advance: 50.0% of your monthly salary (3,210.00 SAR).\n              &nbsp;\n              1,000.00 SAR already outstanding.\n            <br>\n            <strong>\n              Available: 2,210.00 SAR\n            </strong>\n          </p>",
    on_behalf_errors: [ [ "exceeds the employee's available advance limit" ], [ "exceeds the employee's available advance limit" ] ],
    original_card_absent: "<div class=\"info-card\" style=\"margin-top: 1rem;\">\n      <p class=\"info-card__section-title\">Original Attendance</p>\n        <p class=\"info-card__empty\">No attendance record found for this date.</p>\n    </div>",
    original_card_incomplete: "<div class=\"info-card\" style=\"margin-top: 1rem;\">\n      <p class=\"info-card__section-title\">Original Attendance</p>\n        <div class=\"info-card__row\">\n          <span class=\"info-card__label\">Original Check-In</span>\n          <span>Sep 18, 2026 — <bdi dir=\"ltr\" class=\"clock-12h\">08:05 AM</bdi></span>\n        </div>\n        <div class=\"info-card__row\">\n          <span class=\"info-card__label\">Original Check-Out</span>\n          <span>Missing</span>\n        </div>\n        <div class=\"info-card__row\">\n          <span class=\"info-card__label\">Status</span>\n          <span>Checked in</span>\n        </div>\n    </div>",
    original_card_present: "<div class=\"info-card\" style=\"margin-top: 1rem;\">\n      <p class=\"info-card__section-title\">Original Attendance</p>\n        <div class=\"info-card__row\">\n          <span class=\"info-card__label\">Original Check-In</span>\n          <span>Sep 18, 2026 — <bdi dir=\"ltr\" class=\"clock-12h\">08:00 AM</bdi></span>\n        </div>\n        <div class=\"info-card__row\">\n          <span class=\"info-card__label\">Original Check-Out</span>\n          <span>Sep 18, 2026 — <bdi dir=\"ltr\" class=\"clock-12h\">07:00 PM</bdi></span>\n        </div>\n        <div class=\"info-card__row\">\n          <span class=\"info-card__label\">Status</span>\n          <span>Present</span>\n        </div>\n    </div>",
    own_no_profile_errors: [ "cannot be requested because no salary profile is configured for this employee" ],
    own_outstanding_errors: [ "exceeds your available advance limit (210.0 SAR remaining)" ],
    own_over_limit_errors: [ "exceeds your available advance limit (3210.0 SAR remaining)" ],
    own_submitted_by_self_errors: [ "exceeds your available advance limit (3210.0 SAR remaining)" ],
    policy_matrix: { employee_self: { self: { create_advance: true, create_late: true, view_salary: true } }, plain_approver: { employee: { create_advance: false, create_late: true, view_salary: false }, no_profile_employee: { create_advance: false, create_late: true, view_salary: false } }, payroll_approver: { employee: { create_advance: true, create_late: true, view_salary: true }, no_profile_employee: { create_advance: true, create_late: true, view_salary: true } }, outside_payroll_approver: { employee: { create_advance: false, create_late: true, view_salary: false }, no_profile_employee: { create_advance: false, create_late: true, view_salary: false } }, branch_payroll_manager: { employee: { create_advance: true, create_late: true, view_salary: true }, no_profile_employee: { create_advance: true, create_late: true, view_salary: true } }, payroll_without_approve: { employee: { create_advance: false, create_late: false, view_salary: true }, no_profile_employee: { create_advance: false, create_late: false, view_salary: true } }, owner: { employee: { create_advance: true, create_late: true, view_salary: true }, no_profile_employee: { create_advance: true, create_late: true, view_salary: true } } },
    resulting_critical: "<div class=\"info-card resulting-duration resulting-duration--critical\"\n     style=\"margin-top: 1rem;\" data-testid=\"resulting-duration\">\n  <p class=\"info-card__section-title\">Work duration after correction</p>\n\n    <p class=\"resulting-duration__value\" data-testid=\"resulting-duration-value\">15h 0m</p>\n\n    <div class=\"alert alert-danger resulting-duration__warning\"\n         role=\"alert\" data-testid=\"resulting-duration-warning\" data-severity=\"critical\">\n      <p class=\"window-alert__title\">\n        🔴 Abnormal work duration\n      </p>\n      <p>This duration exceeds 14 hours and requires review.</p>\n    </div>\n</div>",
    resulting_normal: "<div class=\"info-card resulting-duration \"\n     style=\"margin-top: 1rem;\" data-testid=\"resulting-duration\">\n  <p class=\"info-card__section-title\">Work duration after correction</p>\n\n    <p class=\"resulting-duration__value\" data-testid=\"resulting-duration-value\">9h 0m</p>\n\n</div>",
    resulting_suspicious: "<div class=\"info-card resulting-duration resulting-duration--suspicious\"\n     style=\"margin-top: 1rem;\" data-testid=\"resulting-duration\">\n  <p class=\"info-card__section-title\">Work duration after correction</p>\n\n    <p class=\"resulting-duration__value\" data-testid=\"resulting-duration-value\">11h 30m</p>\n\n    <div class=\"alert alert-warning resulting-duration__warning\"\n         role=\"alert\" data-testid=\"resulting-duration-warning\" data-severity=\"suspicious\">\n      <p class=\"window-alert__title\">\n        ⚠️ Abnormal work duration\n      </p>\n      <p>This duration exceeds 10 hours and requires review.</p>\n    </div>\n</div>"
  }.freeze

  module_function

  # The raw bytes of the element whose opening tag contains `marker`, through its
  # matching closing tag (same-name nesting counted).
  def raw_element(body, marker)
    at = body.index(marker) or return nil
    raw_element_at(body, body.rindex("<", at))
  end

  # The raw bytes of the element whose opening tag starts at `start`.
  def raw_element_at(body, start)
    name  = body[start + 1..][/\A[a-z0-9]+/]
    depth = 0
    body.to_enum(:scan, %r{<(/?)#{name}\b[^>]*>}).each do
      match = Regexp.last_match
      next if match.begin(0) < start

      depth += match[1].empty? ? 1 : -1
      return body[start...match.end(0)] if depth.zero?
    end
    nil
  end

  def check_ins_attribute(body) = body[/data-punch-order-guard-check-ins-value="[^"]*"/]

  # The hint as a Hash (BUG-037): recent_check_ins promises no order (the form
  # looks entries up by work date), so compare entries, not the attribute bytes.
  # Nokogiri decodes the attribute's HTML entities.
  def check_ins_hash(attribute)
    JSON.parse(Nokogiri::HTML.fragment("<i #{attribute}></i>").at_css("i")["data-punch-order-guard-check-ins-value"])
  end
end

RSpec.describe "Characterization: Workforce request-validation reads (Batch V M1)", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  include RequestValidationReadsCharacterization


  def pin(key, actual) = expect(actual).to(eq(RequestValidationReadsCharacterization::RECORDED.fetch(key)))

  let(:riyadh) { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:business) do
    create(:business, name: "Pulse Co", timezone: "Asia/Riyadh", business_day_start_hour: 0,
                      max_salary_advance_percentage: 50).tap do |b|
      b.update!(attendance_suspicious_duration_hours: 10, attendance_critical_duration_hours: 14)
    end
  end
  let(:branch_a) { create(:branch, business: business, name: "Branch A") }
  let(:branch_b) { create(:branch, business: business, name: "Branch B") }
  let(:shift) do
    Time.use_zone(business.timezone) { create(:shift, :fixed_time, business: business, start_time: "08:00", end_time: "17:00") }
  end
  let!(:assignment) do
    create(:shift_assignment, business: business, user: employee, branch: branch_a, shift: shift,
                              effective_from: Date.new(2026, 1, 1), effective_to: nil)
  end
  let(:employee) do
    create(:user, business: business, first_name: "Sara", last_name: "Ali", preferred_locale: "en")
  end
  let!(:profile) { create(:salary_profile, :monthly, user: employee, base_amount: 6420, effective_from: Date.new(2026, 1, 1)) }
  let(:no_profile_employee) do
    create(:user, business: business, first_name: "Omar", last_name: "Nour", preferred_locale: "en").tap do |u|
      create(:shift_assignment, business: business, user: u, branch: branch_a, shift: shift,
                                effective_from: Date.new(2026, 1, 1), effective_to: nil)
    end
  end

  def approver(*extra, scopes: {}, **attrs)
    api_user_with(business, :view_requests, :approve_requests, :view_employees, *extra,
                  scopes: RequestValidationReadsCharacterization::APPROVER_SCOPES.merge(scopes), preferred_locale: "en", **attrs)
  end

  def payroll_approver = approver(:view_payroll, scopes: { "view_payroll" => "business" }, first_name: "Pay", last_name: "Roll")
  def plain_approver   = approver(first_name: "No", last_name: "Payroll")

  # view_payroll with the hierarchy default, managing another branch only.
  def outside_payroll_approver
    approver(:view_payroll, first_name: "Out", last_name: "Side").tap { |u| branch_b.update_column(:branch_manager_id, u.id) }
  end

  # view_payroll with the hierarchy default, managing the employee's branch.
  def branch_payroll_manager
    approver(:view_payroll, first_name: "Branch", last_name: "Manager").tap { |u| branch_a.update_column(:branch_manager_id, u.id) }
  end

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)

  around { |example| travel_to(riyadh.local(2026, 9, 20, 12, 0)) { example.run } }

  def salary_views = AuditLog.where(action: "view_salary")

  def body = response.body

  # ── Site 1 ───────────────────────────────────────────────────────────────────
  describe "site 1 — EmployeeRequest#within_advance_limit" do
    def advance(user:, amount:, submitted_by: nil)
      build(:employee_request, :salary_advance, user: user, amount: amount, requested_for_date: Date.new(2026, 9, 20),
                                                submitted_by: submitted_by)
    end

    it "accepts an amount within the limit (50% of 6,420.00 = 3,210.00) and the exact limit" do
      expect(advance(user: employee, amount: 3000)).to be_valid
      expect(advance(user: employee, amount: 3210)).to be_valid
    end

    it "refuses the employee's own request above the limit with the remaining amount and currency" do
      request = advance(user: employee, amount: 3210.01)
      expect(request).not_to be_valid
      pin(:own_over_limit_errors, request.errors[:amount])
    end

    it "counts this month's pending advance against the limit" do
      create(:employee_request, :salary_advance, user: employee, amount: 3000, requested_for_date: Date.new(2026, 9, 5))
      request = advance(user: employee, amount: 211)
      expect(request).not_to be_valid
      pin(:own_outstanding_errors, request.errors[:amount])
      expect(advance(user: employee, amount: 210)).to be_valid
    end

    it "refuses the employee's own request without a salary profile" do
      request = advance(user: no_profile_employee, amount: 1)
      expect(request).not_to be_valid
      pin(:own_no_profile_errors, request.errors[:amount])
    end

    it "gives a submitter acting on behalf one message for both over-limit and no-profile" do
      submitter = payroll_approver
      over = advance(user: employee, amount: 5000, submitted_by: submitter)
      none = advance(user: no_profile_employee, amount: 1, submitted_by: submitter)
      expect([ over, none ].map(&:valid?)).to eq([ false, false ])
      pin(:on_behalf_errors, [ over.errors[:amount], none.errors[:amount] ])
      expect(over.errors[:amount]).to eq(none.errors[:amount])
    end

    it "treats the employee as the submitter when submitted_by is the employee" do
      request = advance(user: employee, amount: 5000, submitted_by: employee)
      expect(request).not_to be_valid
      pin(:own_submitted_by_self_errors, request.errors[:amount])
    end

    it "is unrestricted when the business configures no percentage (no limit, no profile needed)" do
      business.update!(max_salary_advance_percentage: nil)
      expect(advance(user: employee, amount: 999_999)).to be_valid
      expect(advance(user: no_profile_employee, amount: 999_999)).to be_valid
    end
  end

  # ── Site 2 ───────────────────────────────────────────────────────────────────
  describe "site 2 — the form's advance-limit hint, visibility decision and salary-view audit" do
    def hint = raw_element(body, 'id="advance-limit-hint"')

    def open_form(for_user: nil)
      get new_employee_request_path(for_user_id: for_user&.id)
      expect(response).to have_http_status(:ok)
    end

    it "own form: the limit hint (no outstanding), no salary-view audit" do
      sign_in employee
      expect { open_form }.not_to change(salary_views, :count)
      pin(:hint_own, hint)
    end

    it "own form with an outstanding advance this month: the outstanding line, no audit" do
      create(:employee_request, :salary_advance, user: employee, amount: 1000, requested_for_date: Date.new(2026, 9, 3))
      sign_in employee
      expect { open_form }.not_to change(salary_views, :count)
      pin(:hint_own_outstanding, hint)
    end

    it "own form without a salary profile: the no-profile hint, no audit" do
      sign_in no_profile_employee
      expect { open_form }.not_to change(salary_views, :count)
      pin(:hint_own_no_profile, hint)
    end

    it "own form with no configured percentage: no hint, no audit" do
      business.update!(max_salary_advance_percentage: nil)
      sign_in employee
      expect { open_form }.not_to change(salary_views, :count)
      expect(hint).to be_nil
    end

    it "on behalf, the actor may view the salary: the employee's limit hint and one audited salary view" do
      actor = payroll_approver
      sign_in actor
      expect { open_form(for_user: employee) }.to change(salary_views, :count).by(1)
      pin(:hint_on_behalf_visible, hint)

      view = salary_views.sole
      expect([ view.actor_id, view.auditable_type, view.auditable_id, view.business_id ])
        .to eq([ actor.id, "User", employee.id, business.id ])
      expect(view.metadata).to eq("source" => "request_advance_limit", "self_view" => false,
                                  "salary_profile_ids" => [ profile.id ])
      expect(view.changes_json).to eq({})
    end

    it "on behalf, visible, employee without a profile: the no-profile hint and no audit" do
      sign_in payroll_approver
      expect { open_form(for_user: no_profile_employee) }.not_to change(salary_views, :count)
      pin(:hint_on_behalf_no_profile, hint)
    end

    it "on behalf, hierarchy-default view_payroll over the employee's branch: visible and audited" do
      sign_in branch_payroll_manager
      expect { open_form(for_user: employee) }.to change(salary_views, :count).by(1)
      expect(hint).to eq(RequestValidationReadsCharacterization::RECORDED.fetch(:hint_on_behalf_visible))
    end

    {
      "without view_payroll"                      => :plain_approver,
      "with view_payroll outside the employee's scope" => :outside_payroll_approver
    }.each do |label, actor|
      it "on behalf, #{label}: the hidden hint and no audit, for an employee with or without a profile" do
        sign_in send(actor)
        expect { open_form(for_user: employee) }.not_to change(salary_views, :count)
        pin(:hint_on_behalf_hidden, hint)
        expect { open_form(for_user: no_profile_employee) }.not_to change(salary_views, :count)
        expect(hint).to eq(RequestValidationReadsCharacterization::RECORDED.fetch(:hint_on_behalf_hidden))
      end
    end

    it "on behalf, visible: every 422 re-render of the form is another audited salary view (any request type)" do
      sign_in payroll_approver
      expect do
        post employee_requests_path, params: { for_user_id: employee.id,
                                               employee_request: { request_type: "salary_advance", amount: 5000,
                                                                   requested_for_date: Date.new(2026, 9, 20), reason: "rent" } }
      end.to change(salary_views, :count).by(1)
      expect(response).to have_http_status(:unprocessable_entity)
      pin(:hint_on_behalf_422, hint)

      expect do
        post employee_requests_path, params: { for_user_id: employee.id,
                                               employee_request: { request_type: "late_permission", duration_minutes: 30,
                                                                   requested_for_date: Date.new(2026, 9, 19), reason: "" } }
      end.to change(salary_views, :count).by(1)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "own form, 422 re-render: the hint again, still no audit" do
      sign_in employee
      expect do
        post employee_requests_path, params: { employee_request: { request_type: "salary_advance", amount: 5000,
                                                                   requested_for_date: Date.new(2026, 9, 20), reason: "rent" } }
      end.not_to change(salary_views, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      pin(:hint_own_422, hint)
    end
  end

  # ── Site 5 ───────────────────────────────────────────────────────────────────
  describe "site 5 — EmployeeRequestPolicy#create? for on-behalf salary advances" do
    def advance_for(user) = EmployeeRequest.new(user: user, request_type: "salary_advance")

    def outcomes(actor, targets)
      targets.to_h do |name, target|
        [ name, {
          create_advance: EmployeeRequestPolicy.new(actor, advance_for(target)).create?,
          create_late:    EmployeeRequestPolicy.new(actor, EmployeeRequest.new(user: target, request_type: "late_permission")).create?,
          view_salary:    SalaryProfilePolicy.new(actor, SalaryProfile.new(user_id: target.id)).view_salary?
        } ]
      end
    end

    let(:targets) { { employee: employee, no_profile_employee: no_profile_employee } }

    it "pins the outcome matrix per actor" do
      matrix = {
        employee_self:            outcomes(employee, { self: employee }),
        plain_approver:           outcomes(plain_approver, targets),
        payroll_approver:         outcomes(payroll_approver, targets),
        outside_payroll_approver: outcomes(outside_payroll_approver, targets),
        branch_payroll_manager:   outcomes(branch_payroll_manager, targets),
        payroll_without_approve:  outcomes(api_user_with(business, :view_payroll, scopes: { "view_payroll" => "business" }), targets),
        owner:                    outcomes(create(:user, :owner, business: business), targets)
      }
      pin(:policy_matrix, matrix)
    end

    it "on another employee's behalf, create? for an advance equals view_salary? whenever the approver gate passes" do
      [ plain_approver, payroll_approver, outside_payroll_approver, branch_payroll_manager ].each do |actor|
        targets.each_value do |target|
          gate = EmployeeRequestPolicy.new(actor, EmployeeRequest.new(user: target, request_type: "late_permission")).create?
          next unless gate

          expect(EmployeeRequestPolicy.new(actor, advance_for(target)).create?)
            .to eq(SalaryProfilePolicy.new(actor, SalaryProfile.new(user_id: target.id)).view_salary?)
        end
      end
    end

    it "web create: accepted on behalf with salary visibility, refused (302, not authorized, nothing written) without" do
      sign_in payroll_approver
      expect do
        post employee_requests_path, params: { for_user_id: employee.id,
                                               employee_request: { request_type: "salary_advance", amount: 3000,
                                                                   requested_for_date: Date.new(2026, 9, 20), reason: "rent" } }
      end.to change { EmployeeRequest.where(user: employee, request_type: "salary_advance").count }.by(1)
      expect(response).to redirect_to(employee_requests_path)

      sign_in plain_approver
      expect do
        post employee_requests_path, params: { for_user_id: employee.id,
                                               employee_request: { request_type: "salary_advance", amount: 3000,
                                                                   requested_for_date: Date.new(2026, 9, 20), reason: "rent" } }
      end.not_to change(EmployeeRequest, :count)
      expect([ response.status, response.location, flash[:alert] ])
        .to eq([ 302, "http://www.example.com/", I18n.t("flash.not_authorized") ])
    end

    describe "API path (POST /api/v1/employee_requests): the signed-in user's own request only" do
      def api_advance(amount, **extra)
        post "/api/v1/employee_requests", params: { **extra, employee_request: { request_type: "salary_advance", amount: amount,
                                                                                requested_for_date: "2026-09-20", reason: "rent" } },
                                          as: :json
      end

      it "creates within the limit, refuses above it with the own-limit message" do
        sign_in employee
        expect { api_advance(3000) }.to change { EmployeeRequest.where(user: employee).count }.by(1)
        expect(response).to have_http_status(:created)

        expect { api_advance(500) }.not_to change(EmployeeRequest, :count)
        pin(:api_over_limit, [ response.status, response.parsed_body ])
      end

      it "ignores for_user_id / user_id: an approver's request is their own, no salary-view audit" do
        actor = payroll_approver
        create(:salary_profile, :monthly, user: actor, base_amount: 1000, effective_from: Date.new(2026, 1, 1))
        sign_in actor
        expect { api_advance(100, for_user_id: employee.id, user_id: employee.id) }
          .to change { EmployeeRequest.where(user: actor).count }.by(1)
          .and not_change { EmployeeRequest.where(user: employee).count }
          .and not_change(salary_views, :count)
      end

      it "refuses the employee without a salary profile with the no-profile message" do
        sign_in no_profile_employee
        expect { api_advance(1) }.not_to change(EmployeeRequest, :count)
        pin(:api_no_profile, [ response.status, response.parsed_body ])
      end
    end
  end

  # ── Sites 3, 6, 7 ────────────────────────────────────────────────────────────
  describe "sites 3, 6 and 7 — the show page's attendance details and duration thresholds" do
    let(:work_date) { Date.new(2026, 9, 18) }
    let(:reviewer) { approver(first_name: "Rev", last_name: "Iewer").tap { |u| branch_a.update_column(:branch_manager_id, u.id) } }

    def record_with(check_in:, check_out:, worked_minutes:, status:)
      create(:attendance_record, user: employee, branch: branch_a, shift_assignment: assignment, date: work_date,
                                 work_date: work_date, check_in_at: check_in, check_out_at: check_out,
                                 worked_minutes: worked_minutes, status: status)
    end

    def correction(type: "wrong_check_out_time", time: "17:00", date: nil)
      create(:employee_request, :punch_correction, user: employee, correction_type: type,
                                                   requested_for_date: work_date, proposed_date: date, proposed_time: time)
    end

    def show(request)
      get employee_request_path(request)
      expect(response).to have_http_status(:ok)
    end

    # The "Original Attendance" card: the info-card that contains its section title.
    def original_card
      title = body.index(">#{I18n.t('requests.show.original_attendance', locale: :en)}</p>") or return nil
      raw_element_at(body, body.rindex('<div class="info-card"', title))
    end

    def duration_alert = raw_element(body, 'data-testid="duration-alert"')
    def resulting_card = raw_element(body, 'data-testid="resulting-duration"')

    context "a record with a suspicious duration (11 h > 10 h configured)" do
      before { record_with(check_in: at(18, 8), check_out: at(18, 19), worked_minutes: 660, status: "present") }

      it "reviewer: the duration alert with the business's suspicious threshold, and the original attendance" do
        sign_in reviewer
        show(correction)
        pin(:duration_alert_suspicious, duration_alert)
        pin(:original_card_present, original_card)
      end

      it "requester: the original attendance only — no alert, no resulting-duration panel" do
        sign_in employee
        show(correction)
        expect(duration_alert).to be_nil
        expect(resulting_card).to be_nil
        expect(original_card).to eq(RequestValidationReadsCharacterization::RECORDED.fetch(:original_card_present))
      end
    end

    it "reviewer, critical duration (15 h > 14 h): the alert with the critical threshold" do
      record_with(check_in: at(18, 8), check_out: at(18, 23), worked_minutes: 900, status: "present")
      sign_in reviewer
      show(correction)
      pin(:duration_alert_critical, duration_alert)
    end

    it "reviewer, unremarkable duration (9 h): no alert" do
      record_with(check_in: at(18, 8), check_out: at(18, 17), worked_minutes: 540, status: "present")
      sign_in reviewer
      show(correction)
      expect(duration_alert).to be_nil
    end

    it "a record without a check-out: the missing check-out and its status" do
      record_with(check_in: at(18, 8, 5), check_out: nil, worked_minutes: nil, status: "incomplete")
      sign_in reviewer
      show(correction(type: "missing_check_out", time: "17:00"))
      expect(duration_alert).to be_nil
      pin(:original_card_incomplete, original_card)
    end

    it "no record for the date: the empty state" do
      sign_in reviewer
      show(correction(type: "missing_check_in", time: "08:00"))
      expect(duration_alert).to be_nil
      pin(:original_card_absent, original_card)
    end

    it "a record of another employee on the same date is not shown" do
      other = create(:user, business: business)
      create(:attendance_record, user: other, branch: branch_a, date: work_date, work_date: work_date,
                                 check_in_at: at(18, 7), check_out_at: at(18, 22), worked_minutes: 900, status: "present")
      sign_in reviewer
      show(correction(type: "missing_check_in", time: "08:00"))
      expect(original_card).to eq(RequestValidationReadsCharacterization::RECORDED.fetch(:original_card_absent))
      expect(duration_alert).to be_nil
    end

    describe "site 7 — the resulting-duration panel's threshold" do
      before { record_with(check_in: at(18, 8), check_out: at(18, 9), worked_minutes: 60, status: "present") }

      it "suspicious projection (8:00 → 19:30 = 11 h 30 min > 10 h)" do
        sign_in reviewer
        show(correction(time: "19:30"))
        pin(:resulting_suspicious, resulting_card)
      end

      it "critical projection (8:00 → 23:00 = 15 h > 14 h)" do
        sign_in reviewer
        show(correction(time: "23:00"))
        pin(:resulting_critical, resulting_card)
      end

      it "normal projection (8:00 → 17:00 = 9 h): no warning" do
        sign_in reviewer
        show(correction(time: "17:00"))
        pin(:resulting_normal, resulting_card)
      end
    end
  end

  # ── Site 4 ───────────────────────────────────────────────────────────────────
  describe "site 4 — the form's recent check-in hint" do
    before do
      # Lookback is Date.current - 62 days (2026-07-20) inclusive; check-in times in the business zone.
      [ [ Date.new(2026, 9, 19), at(19, 8, 5) ], [ Date.new(2026, 7, 20), riyadh.local(2026, 7, 20, 7, 59) ],
        [ Date.new(2026, 7, 19), riyadh.local(2026, 7, 19, 9, 0) ], [ Date.new(2026, 9, 18), riyadh.local(2026, 9, 17, 23, 30) ] ]
        .each do |date, check_in|
          create(:attendance_record, user: employee, branch: branch_a, shift_assignment: assignment, date: date,
                                     work_date: date, check_in_at: check_in, status: "incomplete")
        end
      # The query's `where.not(check_in_at: nil)` is not pinned: attendance_records.check_in_at is NOT NULL (and
      # validated), so a row without a check-in cannot exist.
      other = create(:user, business: business)
      create(:attendance_record, user: other, branch: branch_a, date: Date.new(2026, 9, 17), work_date: Date.new(2026, 9, 17),
                                 check_in_at: at(17, 6), status: "incomplete")
    end

    it "own form: the employee's check-ins of the last 62 days, keyed by work date, business-local" do
      sign_in employee
      get new_employee_request_path
      expect(check_ins_hash(check_ins_attribute(body))).to eq(check_ins_hash(RequestValidationReadsCharacterization::RECORDED.fetch(:check_ins_own)))
    end

    it "on behalf: the target employee's check-ins (whatever the actor's salary visibility)" do
      sign_in plain_approver
      get new_employee_request_path(for_user_id: employee.id)
      expect(check_ins_hash(check_ins_attribute(body))).to eq(check_ins_hash(RequestValidationReadsCharacterization::RECORDED.fetch(:check_ins_own)))
    end

    it "422 re-render: the same hint" do
      sign_in employee
      post employee_requests_path, params: { employee_request: { request_type: "late_permission", duration_minutes: 30,
                                                                 requested_for_date: Date.new(2026, 9, 21), reason: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(check_ins_hash(check_ins_attribute(body))).to eq(check_ins_hash(RequestValidationReadsCharacterization::RECORDED.fetch(:check_ins_own)))
    end

    it "an employee without attendance: an empty hint" do
      sign_in no_profile_employee
      get new_employee_request_path
      pin(:check_ins_empty, check_ins_attribute(body))
    end
  end
end
