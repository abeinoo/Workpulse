require "rails_helper"

RSpec.describe "EmployeeRequests", type: :request do
  let(:business)  { create(:business, timezone: "Asia/Riyadh") }
  let(:branch)    { create(:branch, business: business) }
  let(:employee)  { create(:user, business: business) }

  before { sign_in employee }

  # ──────────────────────────────────────────────────────────────
  # Punch Correction — creation
  # ──────────────────────────────────────────────────────────────
  describe "POST /employee_requests (punch_correction)" do
    let(:valid_params) do
      {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_out",
          proposed_time:      "17:00",
          requested_for_date: Date.yesterday.iso8601,
          reason:             "Forgot to clock out"
        }
      }
    end

    it "creates the request and redirects" do
      expect {
        post employee_requests_path, params: valid_params
      }.to change(EmployeeRequest, :count).by(1)

      expect(response).to redirect_to(employee_requests_path)
    end

    it "saves the correct attributes" do
      post employee_requests_path, params: valid_params
      req = EmployeeRequest.last
      expect(req.punch_correction?).to be true
      expect(req.correction_missing_check_out?).to be true
      expect(req.requested_for_date).to eq(Date.yesterday)
      expect(req.affects_payroll).to be false
    end

    it "saves proposed_time" do
      post employee_requests_path, params: valid_params
      expect(EmployeeRequest.last.proposed_time).to eq("17:00")
    end

    it "creates requests for all correction_type values" do
      EmployeeRequest::CORRECTION_TYPES.each do |ct|
        post employee_requests_path, params: {
          employee_request: valid_params[:employee_request].merge(correction_type: ct)
        }
        expect(response).to redirect_to(employee_requests_path), "#{ct} should succeed"
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Punch Correction — validation errors
  # ──────────────────────────────────────────────────────────────
  describe "POST /employee_requests (punch_correction) — validation errors" do
    it "re-renders the form when correction_type is missing" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "",
          proposed_time:      "17:00",
          requested_for_date: Date.yesterday.iso8601,
          reason:             "Forgot to clock out"
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("requests.new.title"))
    end

    it "re-renders the form when proposed_time is missing" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_out",
          proposed_time:      "",
          requested_for_date: Date.yesterday.iso8601,
          reason:             "Forgot to clock out"
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "re-renders the form when reason is missing" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_out",
          requested_for_date: Date.yesterday.iso8601,
          reason:             ""
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "re-renders the form when date is missing" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_out",
          requested_for_date: "",
          reason:             "Forgot to clock out"
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Dashboard link pre-filling the form
  # ──────────────────────────────────────────────────────────────
  describe "GET /employee_requests/new — dashboard pre-fill" do
    it "pre-fills request_type, date, and correction_type from query params" do
      get new_employee_request_path,
          params: {
            request_type:       "punch_correction",
            requested_for_date: Date.yesterday.iso8601,
            correction_type:    "missing_check_out"
          }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("punch_correction")
      expect(response.body).to include(Date.yesterday.iso8601)
      expect(response.body).to include("missing_check_out")
    end

    it "ignores unknown request_type values" do
      get new_employee_request_path, params: { request_type: "unknown_type" }
      expect(response).to have_http_status(:ok)
      # form renders without error
    end

    it "ignores unknown correction_type values" do
      get new_employee_request_path,
          params: { request_type: "punch_correction", correction_type: "invalid_value" }
      expect(response).to have_http_status(:ok)
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Locale — English
  # ──────────────────────────────────────────────────────────────
  describe "GET /employee_requests/new — English locale" do
    around { |ex| I18n.with_locale(:en) { ex.run } }

    it "shows Punch Correction as a request type option" do
      get new_employee_request_path
      expect(response.body).to include(I18n.t("requests.types.punch_correction", locale: :en))
    end

    it "shows all correction type options" do
      EmployeeRequest::CORRECTION_TYPES.each do |ct|
        expect(I18n.t("requests.correction_types.#{ct}", locale: :en)).to be_present
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Locale — Arabic
  # ──────────────────────────────────────────────────────────────
  describe "Arabic locale translations" do
    it "has Arabic translation for punch_correction type" do
      expect(I18n.t("requests.types.punch_correction", locale: :ar)).to eq("طلب تعديل بصمة")
    end

    it "has Arabic translations for all correction types" do
      EmployeeRequest::CORRECTION_TYPES.each do |ct|
        translation = I18n.t("requests.correction_types.#{ct}", locale: :ar)
        expect(translation).not_to include("translation missing"), "Missing AR translation for #{ct}"
      end
    end

    it "has Arabic translation for the dashboard banner title" do
      expect(I18n.t("dashboard.missing_checkout.title", locale: :ar)).to eq("يبدو أنك نسيت تسجيل الانصراف أمس.")
    end

    it "has Arabic translation for the dashboard banner CTA" do
      expect(I18n.t("dashboard.missing_checkout.cta", locale: :ar)).to eq("طلب تعديل بصمة")
    end

    it "renders the form in Arabic when user has Arabic locale" do
      employee.update!(preferred_locale: "ar")
      get new_employee_request_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("طلب تعديل بصمة")
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Overnight punch correction — work date + punch date
  # ──────────────────────────────────────────────────────────────
  describe "POST /employee_requests (overnight punch_correction)" do
    # A 20:00 → 03:00 shift: the 2 Jun 04:00 check-out is within the shift's
    # attendance window for work date 1 Jun, so no out-of-window warning applies.
    before do
      create(:shift_assignment, user: employee, branch: branch, effective_from: Date.new(2026, 5, 1),
             shift: create(:shift, :fixed_time, business: business,
                           start_time: Time.zone.parse("20:00"), end_time: Time.zone.parse("03:00")))
    end

    it "stores requested_for_date (work day) and proposed_date (punch day) separately" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_out",
          requested_for_date: Date.new(2026, 6, 1).iso8601,
          proposed_date:      Date.new(2026, 6, 2).iso8601,
          proposed_time:      "04:00",
          reason:             "Overnight shift, forgot to clock out"
        }
      }
      req = EmployeeRequest.last
      expect(req.requested_for_date).to eq(Date.new(2026, 6, 1))
      expect(req.proposed_date).to eq(Date.new(2026, 6, 2))
    end

    it "defaults proposed_date to the work date when omitted" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_in",
          requested_for_date: Date.new(2026, 6, 1).iso8601,
          proposed_time:      "09:00",
          reason:             "Same-day correction"
        }
      }
      expect(EmployeeRequest.last.proposed_date).to eq(Date.new(2026, 6, 1))
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Index: default ordering + filter bar
  # ──────────────────────────────────────────────────────────────
  describe "GET /employee_requests (index ordering + filters)" do
    let(:manager) do
      role = create(:permission_role, business: business,
                    permissions: %w[view_requests approve_requests],
                    permission_scopes: { "view_requests" => "business_wide" })
      create(:user, business: business, permission_role: role)
    end
    let(:other_employee) { create(:user, business: business, first_name: "Other", last_name: "Worker") }

    let!(:pending_old) { create(:employee_request, :late_permission, user: employee, status: :pending, created_at: 3.days.ago) }
    let!(:pending_new) { create(:employee_request, :late_permission, user: other_employee, status: :pending, created_at: 1.hour.ago) }
    let!(:approved)    { create(:employee_request, :early_leave,     user: employee, status: :approved) }
    let!(:rejected)    { create(:employee_request, :early_leave,     user: employee, status: :rejected) }

    it "orders pending first (newest first), then approved, then rejected" do
      sign_in manager
      get employee_requests_path

      body = response.body
      positions = [ pending_new, pending_old, approved, rejected ].map { |r| body.index(employee_request_path(r)) }
      expect(positions).to eq(positions.compact.sort) # already in ascending document order
      expect(positions).to all(be_present)
    end

    it "filters by status at the database level" do
      sign_in manager
      get employee_requests_path(status: "approved")

      expect(response.body).to include(employee_request_path(approved))
      expect(response.body).not_to include(employee_request_path(pending_old))
      expect(response.body).not_to include(employee_request_path(rejected))
    end

    it "filters by employee" do
      sign_in manager
      get employee_requests_path(user_id: other_employee.id)

      expect(response.body).to include(employee_request_path(pending_new))
      expect(response.body).not_to include(employee_request_path(pending_old))
    end

    it "renders active filter chips and a clear link when filters are applied" do
      sign_in manager
      get employee_requests_path(status: "approved")

      expect(response.body).to include("filter-chip")
      expect(response.body).to include(I18n.t("requests.filters.clear"))
      expect(response.body).to include(I18n.t("requests.statuses.approved"))
    end

    it "shows no chips when unfiltered" do
      sign_in manager
      get employee_requests_path

      expect(response.body).not_to include("filter-chip")
    end

    it "limits the employee filter dropdown to employees in the viewer's scope" do
      outsider_role = create(:permission_role, business: business,
                             permissions: %w[view_requests approve_requests],
                             permission_scopes: { "view_requests" => "branch" })
      branch_mgr = create(:user, business: business, permission_role: outsider_role)
      br = create(:branch, business: business, branch_manager_id: branch_mgr.id)
      in_scope = create(:user, business: business, first_name: "Inscope", last_name: "Report")
      create(:shift_assignment, user: in_scope, branch: br,
             shift: create(:shift, :fixed_time, business: business))
      sign_in branch_mgr

      get employee_requests_path
      expect(response.body).to include("Inscope Report")        # selectable in the picker
      expect(response.body).not_to include("Other Worker")      # out of this manager's scope
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Manager review: reject with reason + employee visibility
  # ──────────────────────────────────────────────────────────────
  describe "manager review" do
    let(:manager) do
      role = create(:permission_role, business: business,
                    permissions: %w[view_requests approve_requests])
      create(:user, business: business, permission_role: role)
    end

    before do
      # Shift-driven membership: `manager` manages `branch`, employee assigned there.
      branch.update_column(:branch_manager_id, manager.id)
      create(:shift_assignment, user: employee, branch: branch,
             shift: create(:shift, :fixed_time, business: business))
    end

    it "stores reviewer, time and reason on reject" do
      request = create(:employee_request, :early_leave, user: employee, status: :pending)
      sign_in manager

      patch reject_employee_request_path(request),
            params: { response_note: "Insufficient coverage that day" }

      request.reload
      expect(request).to be_rejected
      expect(request.reviewed_by).to eq(manager)
      expect(request.reviewed_at).to be_present
      expect(request.response_note).to eq("Insufficient coverage that day")
    end

    it "shows the rejection reason to the requesting employee" do
      request = create(:employee_request, :salary_advance, user: employee,
                       status: :rejected, reviewed_by: manager,
                       reviewed_at: Time.current, response_note: "Over the limit")
      sign_in employee

      get employee_request_path(request)
      expect(response.body).to include("Over the limit")
      expect(response.body).to include(I18n.t("requests.rejection_reason"))
    end
  end

  # ──────────────────────────────────────────────────────────────
  # On-behalf-of picker honours the approver's data scope
  # ──────────────────────────────────────────────────────────────
  describe "on-behalf-of employee scope" do
    let!(:unmanaged) { create(:user, business: business, first_name: "Unmanaged", last_name: "Person") }

    it "lets a business-wide approver pick and submit for any business employee" do
      role = create(:permission_role, business: business,
                    permissions: %w[view_requests approve_requests],
                    permission_scopes: { "approve_requests" => "business_wide" })
      wide_approver = create(:user, business: business, permission_role: role)
      sign_in wide_approver

      get new_employee_request_path
      expect(response.body).to include("Unmanaged Person") # appears in the picker

      expect {
        post employee_requests_path, params: {
          for_user_id: unmanaged.id,
          employee_request: {
            request_type: "early_leave", duration_minutes: 30,
            requested_for_date: Date.current.iso8601, reason: "Doctor",
            for_user_id: unmanaged.id
          }
        }
      }.to change { EmployeeRequest.where(user: unmanaged).count }.by(1)
    end

    it "blocks a branch-scoped approver from submitting for an out-of-scope employee" do
      role = create(:permission_role, business: business,
                    permissions: %w[view_requests approve_requests],
                    permission_scopes: { "approve_requests" => "branch" })
      restricted = create(:user, business: business, permission_role: role)
      sign_in restricted

      # The out-of-scope target is rejected by resolve_for_user (falls back to the
      # approver), so crucially NO request is created for the unmanaged employee.
      expect {
        post employee_requests_path, params: {
          for_user_id: unmanaged.id,
          employee_request: {
            request_type: "early_leave", duration_minutes: 30,
            requested_for_date: Date.current.iso8601, reason: "Doctor",
            for_user_id: unmanaged.id
          }
        }
      }.not_to change { EmployeeRequest.where(user: unmanaged).count }
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Early-leave display: minutes + requested departure time
  # ──────────────────────────────────────────────────────────────
  describe "early-leave display" do
    it "shows requested minutes on the detail page" do
      request = create(:employee_request, :early_leave, user: employee,
                       duration_minutes: 45, requested_for_date: Date.current)
      get employee_request_path(request)
      expect(response.body).to include(I18n.t("requests.show.minutes_requested"))
      expect(response.body).to include("45")
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Requester self-service cancel
  # ──────────────────────────────────────────────────────────────
  describe "PATCH /employee_requests/:id/cancel" do
    it "lets the requester cancel their own pending request" do
      request = create(:employee_request, :early_leave, user: employee, status: :pending)

      patch cancel_employee_request_path(request), params: { cancellation_reason: "No longer needed" }

      expect(response).to redirect_to(employee_request_path(request))
      request.reload
      expect(request.status).to eq("cancelled")
      expect(request.cancelled_by).to eq(employee)
      expect(request.cancellation_reason).to eq("No longer needed")
    end

    it "does NOT let a different employee cancel someone else's pending request" do
      viewer_role = create(:permission_role, business: business, permissions: %w[view_requests],
                           permission_scopes: { "view_requests" => "business_wide" })
      other = create(:user, business: business, permission_role: viewer_role)
      sign_in other
      request = create(:employee_request, :early_leave, user: employee, status: :pending)

      patch cancel_employee_request_path(request), params: { cancellation_reason: "x" }

      expect(response).to redirect_to(root_path)
      expect(request.reload.status).to eq("pending")
    end

    it "does NOT let the requester cancel their own rejected request" do
      request = create(:employee_request, :early_leave, user: employee, status: :rejected,
                       reviewed_at: Time.current)

      patch cancel_employee_request_path(request), params: { cancellation_reason: "x" }

      expect(response).to redirect_to(root_path)
      expect(request.reload.status).to eq("rejected")
    end

    it "lets an approver cancel an already-approved request" do
      role = create(:permission_role, business: business, permissions: %w[view_requests approve_requests],
                    permission_scopes: { "view_requests" => "business_wide" })
      manager = create(:user, business: business, permission_role: role)
      sign_in manager
      request = create(:employee_request, :early_leave, user: employee, status: :approved,
                       reviewed_at: Time.current)

      patch cancel_employee_request_path(request), params: { cancellation_reason: "Approved by mistake" }

      expect(request.reload.status).to eq("cancelled")
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Bulk "Mark Selected as Paid"
  # ──────────────────────────────────────────────────────────────
  describe "PATCH /employee_requests/bulk_pay" do
    let(:accountant) { create(:user, :accountant, business: business) }

    def approved_advance(amount: 1_000.0)
      create(:employee_request, :salary_advance, :approved, amount: amount,
             user: create(:user, business: business))
    end

    context "as an accountant who can pay advances" do
      before { sign_in accountant }

      it "marks the selected advances as paid and creates Advances" do
        r1 = approved_advance(amount: 1_000.0)
        r2 = approved_advance(amount: 2_000.0)

        expect {
          patch bulk_pay_employee_requests_path,
                params: { request_ids: [r1.id, r2.id], paid_at: Date.current.iso8601 }
        }.to change(Advance, :count).by(2)

        expect(r1.reload).to be_paid
        expect(r2.reload).to be_paid
        expect(response).to redirect_to(employee_requests_path)
        expect(flash[:notice]).to be_present
      end

      it "records a bulk audit log entry" do
        r1 = approved_advance

        expect {
          patch bulk_pay_employee_requests_path,
                params: { request_ids: [r1.id], paid_at: Date.current.iso8601, notes: "Cash" }
        }.to change { AuditLog.where(action: "bulk_pay_advances").count }.by(1)

        expect(r1.reload.response_note).to eq("Cash")
      end

      it "pays valid advances and reports skipped ones on partial failure" do
        valid    = approved_advance(amount: 1_000.0)
        pending  = create(:employee_request, :salary_advance, amount: 500.0,
                          user: create(:user, business: business))

        patch bulk_pay_employee_requests_path,
              params: { request_ids: [valid.id, pending.id], paid_at: Date.current.iso8601 }

        expect(valid.reload).to be_paid
        expect(pending.reload).to be_pending
        expect(flash[:notice]).to be_present
        expect(flash[:alert]).to be_present # skipped notice
      end

      it "shows an alert when none of the selected requests are payable" do
        pending = create(:employee_request, :salary_advance, amount: 500.0,
                         user: create(:user, business: business))

        patch bulk_pay_employee_requests_path, params: { request_ids: [pending.id] }

        expect(pending.reload).to be_approved.or be_pending
        expect(flash[:alert]).to be_present
        expect(flash[:notice]).to be_blank
      end

      it "cannot pay advances belonging to another business (out of scope)" do
        other_business = create(:business)
        foreign = create(:employee_request, :salary_advance, :approved, amount: 900.0,
                         user: create(:user, business: other_business))

        expect {
          patch bulk_pay_employee_requests_path, params: { request_ids: [foreign.id] }
        }.not_to change(Advance, :count)

        expect(foreign.reload).to be_approved
      end
    end

    context "as an employee without pay_advances permission" do
      before { sign_in employee }

      it "is not authorized and does not pay" do
        advance = approved_advance

        expect {
          patch bulk_pay_employee_requests_path, params: { request_ids: [advance.id] }
        }.not_to change(Advance, :count)

        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
        expect(advance.reload).to be_approved
      end
    end
  end
end
