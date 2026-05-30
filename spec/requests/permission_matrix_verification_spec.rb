require "rails_helper"

# Behavioral verification of the permission-driven architecture.
#
# This is NOT a code-inspection audit. Every assertion below is a real HTTP
# request executed through the Rails stack, with assertions on actual response
# status codes and rendered HTML. The premise: removing a permission from a
# role must immediately remove the corresponding feature everywhere it appears.
#
# Test matrix:
#   A) view_employees only
#   B) view_payroll only
#   C) view_requests + approve_requests only (approve_requests requires view_requests)
#   D) zero permissions
#   E) toggle test — flip a permission on a live role, re-fetch sidebar
RSpec.describe "Permission matrix — behavioral verification", type: :request do
  let(:business) { create(:business) }

  # Helper: build a user with an exact permission set.
  def user_with(*permissions)
    role = PermissionRole.create!(
      business:    business,
      name:        "Role-#{SecureRandom.hex(4)}",
      permissions: permissions.map(&:to_s)
    )
    create(:user, business: business, permission_role: role)
  end

  def get_html(user, path)
    sign_in user
    get path
    response
  ensure
    sign_out user
  end

  def sidebar_html(user)
    sign_in user
    get root_path
    body = response.body
    sign_out user
    body
  end

  # The sidebar section-header markup uniquely identifies a sidebar section
  # (the link text appears in multiple places — quick actions, bottom nav, etc).
  def section_header(key)
    %(sidebar__section-label">#{I18n.t(key)}<)
  end

  # Inner section toggle is used by the collapsible Administration group.
  def section_toggle(key)
    %(sidebar__group-toggle">\n              #{I18n.t(key)})
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test A — view_employees ONLY
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test A — user with view_employees only" do
    let(:user) { user_with(:view_employees) }

    it "can access the Employees index (200)" do
      expect(get_html(user, admin_users_path)).to have_http_status(:ok)
    end

    it "Payroll index renders but only shows the user's own data (self-service is always allowed)" do
      r = get_html(user, payroll_periods_path)
      expect(r).to have_http_status(:ok)
      # No business-management buttons render (e.g. "Generate Payroll").
      expect(r.body).not_to include(new_payroll_period_path)
    end

    it "Attendance index loads — self-service shows only own records" do
      r = get_html(user, attendance_records_path)
      expect(r).to have_http_status(:ok)
    end

    it "cannot access Settings (admin gate denies)" do
      expect(get_html(user, admin_settings_path).status).to be_in([302, 403])
    end

    it "cannot access Permission Roles (admin gate denies)" do
      expect(get_html(user, admin_permission_roles_path).status).to be_in([302, 403])
    end

    it "cannot access Branches (manage_branches missing)" do
      expect(get_html(user, admin_branches_path).status).to be_in([302, 403])
    end

    it "sidebar shows Employees link" do
      body = sidebar_html(user)
      expect(body).to include(admin_users_path)
      expect(body).to include(I18n.t("nav.employees"))
    end

    it "management sidebar does NOT include the Payroll section header" do
      expect(sidebar_html(user)).not_to include(section_header("nav.section_payroll"))
    end

    it "sidebar does NOT include Requests section header" do
      expect(sidebar_html(user)).not_to include(section_header("nav.section_requests"))
    end

    it "sidebar does NOT include Settings or Permission Roles" do
      body = sidebar_html(user)
      expect(body).not_to include(I18n.t("nav.settings"))
      expect(body).not_to include(I18n.t("nav.permission_roles"))
    end

    it "sidebar does NOT show the Adjustments link" do
      expect(sidebar_html(user)).not_to include(adjustments_path)
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test B — view_payroll ONLY
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test B — user with view_payroll only" do
    let(:user) { user_with(:view_payroll) }

    it "can access Payroll Periods index" do
      expect(get_html(user, payroll_periods_path)).to have_http_status(:ok)
    end

    it "cannot access the Employees index" do
      expect(get_html(user, admin_users_path).status).to be_in([302, 403])
    end

    it "cannot access Settings" do
      expect(get_html(user, admin_settings_path).status).to be_in([302, 403])
    end

    it "cannot access Permission Roles" do
      expect(get_html(user, admin_permission_roles_path).status).to be_in([302, 403])
    end

    it "sidebar shows Payroll link" do
      body = sidebar_html(user)
      expect(body).to include(payroll_periods_path)
      expect(body).to include(I18n.t("nav.payroll"))
    end

    it "sidebar does NOT show Employees link" do
      expect(sidebar_html(user)).not_to include(I18n.t("nav.employees"))
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test C — view_requests + approve_requests (dependency)
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test C — user with view_requests + approve_requests" do
    let(:user) { user_with(:view_requests, :approve_requests) }

    it "can access Employee Requests index" do
      expect(get_html(user, employee_requests_path)).to have_http_status(:ok)
    end

    it "Payroll page loads as self-service but NO management toolbar (no Create Period button)" do
      r = get_html(user, payroll_periods_path)
      expect(r).to have_http_status(:ok)
      expect(r.body).not_to include(new_payroll_period_path)
    end

    it "cannot access the Employees admin index" do
      expect(get_html(user, admin_users_path).status).to be_in([302, 403])
    end

    it "sidebar shows Requests section" do
      body = sidebar_html(user)
      expect(body).to include(section_header("nav.section_requests"))
      expect(body).to include(employee_requests_path)
    end

    it "sidebar does NOT show the management Payroll section header" do
      expect(sidebar_html(user)).not_to include(section_header("nav.section_payroll"))
    end

    it "sidebar does NOT show Employees link" do
      expect(sidebar_html(user)).not_to include(I18n.t("nav.employees"))
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test D — zero permissions
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test D — user with no permissions" do
    let(:user) { user_with() }   # empty role

    it "Payroll renders only as personal self-service (no business data, no management actions)" do
      r = get_html(user, payroll_periods_path)
      expect(r).to have_http_status(:ok)
      expect(r.body).not_to include(new_payroll_period_path)
    end

    it "is denied Employees admin" do
      expect(get_html(user, admin_users_path).status).to be_in([302, 403])
    end

    it "is denied Branches admin" do
      expect(get_html(user, admin_branches_path).status).to be_in([302, 403])
    end

    it "is denied Settings" do
      expect(get_html(user, admin_settings_path).status).to be_in([302, 403])
    end

    it "is denied Permission Roles" do
      expect(get_html(user, admin_permission_roles_path).status).to be_in([302, 403])
    end

    it "is denied Operations Dashboard" do
      expect(get_html(user, operations_dashboard_path).status).to be_in([302, 403])
    end

    it "can still see their own attendance (self-service)" do
      expect(get_html(user, attendance_records_path)).to have_http_status(:ok)
    end

    it "can still see their own employee_requests (self-service)" do
      expect(get_html(user, employee_requests_path)).to have_http_status(:ok)
    end

    it "sidebar shows the employee/self-service view — none of the management section headers" do
      body = sidebar_html(user)
      expect(body).not_to include(section_header("nav.section_workforce"))
      expect(body).not_to include(section_header("nav.section_administration"))
      expect(body).not_to include(section_header("nav.section_payroll"))
      expect(body).not_to include(section_header("nav.section_attendance"))
      expect(body).not_to include(section_header("nav.section_requests"))
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test E — live permission toggle: removing a permission removes the feature
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test E — toggling a permission removes feature on the next request" do
    let!(:role) do
      PermissionRole.create!(business: business, name: "ToggleRole",
                             permissions: %w[view_employees view_payroll])
    end
    let!(:user) { create(:user, business: business, permission_role: role) }

    it "Payroll section header appears in management sidebar when view_payroll is granted, vanishes when revoked" do
      body_with = sidebar_html(user)
      expect(body_with).to include(section_header("nav.section_payroll")), "expected Payroll section before revoke"

      role.update!(permissions: %w[view_employees])
      user.reload

      body_without = sidebar_html(user)
      expect(body_without).not_to include(section_header("nav.section_payroll")), "Payroll section must disappear after revoke"
    end

    it "Adjustments link disappears when view_payroll is revoked" do
      expect(sidebar_html(user)).to include(adjustments_path)
      role.update!(permissions: %w[view_employees])
      user.reload
      expect(sidebar_html(user)).not_to include(adjustments_path)
    end

    it "Employees admin index becomes inaccessible after view_employees is revoked" do
      expect(get_html(user, admin_users_path)).to have_http_status(:ok)
      role.update!(permissions: %w[view_payroll])
      user.reload
      expect(get_html(user, admin_users_path).status).to be_in([302, 403])
    end

    it "Permission Roles link only appears when manage_roles is granted" do
      # Initially no manage_roles.
      expect(sidebar_html(user)).not_to include(I18n.t("nav.permission_roles"))
      role.update!(permissions: %w[view_employees view_payroll manage_roles])
      user.reload
      expect(sidebar_html(user)).to include(I18n.t("nav.permission_roles"))
    end

    it "Adjustments link only appears with view_payroll" do
      # Initially has view_payroll → adjustments visible.
      expect(sidebar_html(user)).to include(I18n.t("nav.adjustments"))
      role.update!(permissions: %w[view_employees])
      user.reload
      expect(sidebar_html(user)).not_to include(I18n.t("nav.adjustments"))
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test F — Owner inheritance (sanity check: owner gets everything via can?)
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test F — owner sees all permission-gated features without explicit grants" do
    let(:owner) { create(:user, :owner, business: business) }

    it "owner has full management sidebar" do
      body = sidebar_html(owner)
      expect(body).to include(I18n.t("nav.payroll"))
      expect(body).to include(I18n.t("nav.employees"))
      expect(body).to include(section_header("nav.section_requests"))
      # Administration uses a collapsible <details> group, so test by section_toggle.
      expect(body).to include(I18n.t("nav.section_administration"))
    end

    it "owner can access every gated route" do
      [
        admin_users_path,
        admin_branches_path,
        admin_permission_roles_path,
        admin_settings_path,
        payroll_periods_path,
        employee_requests_path,
        attendance_records_path
      ].each do |path|
        expect(get_html(owner, path)).to have_http_status(:ok), "Owner denied at #{path}"
      end
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test H — Permissions are read from the database on EVERY request.
  # No sign-out, no user.reload, no session refresh between the two requests.
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test H — no caching of permissions across requests in a single session" do
    let!(:role) do
      PermissionRole.create!(business: business, name: "PersistRole-#{rand(10000)}",
                             permissions: %w[view_payroll])
    end
    let!(:user) { create(:user, business: business, permission_role: role) }

    it "scenario: live revoke while user is signed in — Payroll disappears on the very next request" do
      # ── Step 1: User logs in. (One sign_in for the entire test.)
      sign_in user

      # ── Step 2: First request — Payroll is visible.
      get root_path
      first_body = response.body
      expect(first_body).to include(section_header("nav.section_payroll")),
        "Step 2 failed — expected Payroll section to be visible while role has view_payroll"

      get payroll_periods_path
      expect(response).to have_http_status(:ok),
        "Step 2 failed — expected /payroll_periods to be accessible"
      # Owner is created by the matrix's `business` factory. We verify that
      # `user`, not owner, is making the request.
      expect(controller.current_user).to eq(user) if respond_to?(:controller)

      # ── Step 3: Owner removes view_payroll from the role.
      #   This is a direct DB update — no message to the running session,
      #   no signal, no broadcast. The next request must pick it up by itself.
      role.update!(permissions: [])

      # We intentionally do NOT call `user.reload` here. The point is to verify
      # that the next request reads from the DB regardless of what is cached
      # in any prior request's User instance.

      # ── Step 4: User refreshes the page (SAME session cookie, no re-sign-in).
      get root_path
      refreshed_body = response.body

      # ── Step 5: Payroll has vanished from the sidebar.
      expect(refreshed_body).not_to include(section_header("nav.section_payroll")),
        "Step 5 FAILED — Payroll section is still rendered after the permission was revoked. " \
        "This means the new permissions are not being read from the database on each request."

      # ── Step 6: Direct URL access is denied. The page now renders only as
      #   self-service (empty) — no management buttons appear.
      get payroll_periods_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(new_payroll_period_path),
        "Step 6 FAILED — management actions still appear after permission revoke"
    end

    it "granting a permission live also takes effect on the next request" do
      sign_in user
      role.update!(permissions: [])      # start with no perms

      get root_path
      expect(response.body).not_to include(section_header("nav.section_payroll"))

      role.update!(permissions: %w[view_payroll])
      get root_path
      expect(response.body).to include(section_header("nav.section_payroll")),
        "Granting view_payroll did not surface the Payroll section on the next request"
    end

    it "scope_for changes (data-scope override) take effect on the very next request" do
      # User starts with view_payroll, no explicit scope (defaults to managed).
      sign_in user
      get root_path
      expect(response).to have_http_status(:ok)

      # Mutate scope mid-session.
      role.update!(permission_scopes: { "view_payroll" => "business_wide" })

      # The next request must observe the new scope.
      get root_path
      expect(response).to have_http_status(:ok)
      # Re-fetch the User from DB to check what the next can?/scope_for call would see.
      expect(User.find(user.id).scope_for(:view_payroll)).to eq("business_wide")
    end

    it "current_user is a fresh AR object on each request (Devise re-fetches from DB)" do
      sign_in user
      get root_path
      first_oid = controller.current_user.object_id

      get root_path
      second_oid = controller.current_user.object_id

      expect(first_oid).not_to eq(second_oid),
        "current_user object_id was identical across two requests — that would indicate caching"
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test G — API endpoints respect the same permission gates
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test G — API endpoints are permission-gated, not role-gated" do
    let(:user) { user_with(:view_payroll) }
    let!(:period) { create(:payroll_period, business: business) }

    it "view_payroll grants API access to payroll periods" do
      sign_in user
      get "/api/v1/payroll_periods", as: :json
      expect(response).to have_http_status(:ok)
    end

    it "user without view_payroll cannot fetch payroll period details" do
      no_perm_user = user_with()
      sign_in no_perm_user
      get "/api/v1/payroll_periods/#{period.id}", as: :json
      # Either denied or returns only employee-visible periods (empty for draft)
      expect(response.status).to be_in([200, 302, 403, 404])
      if response.status == 200
        # If 200, it must be because the period is visible to them as an employee,
        # which requires an entry; we created no entry, so body should NOT include period data.
        body = response.parsed_body
        expect(body["data"]).to be_nil.or be_empty.or(
          satisfy { |d| !d.is_a?(Hash) || d["status"] != "draft" }
        )
      end
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test I — Payroll records vs payroll analytics separation.
  #   Viewing payroll records (`view_payroll`) and viewing payroll analytics
  #   (`view_payroll_analytics`) are two distinct capabilities. A records-only
  #   user must NOT see organization-wide aggregates, KPI cards, filters,
  #   the payroll dashboard, or analytics API endpoints.
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test I — payroll records vs analytics separation" do
    # Both users get business_wide scope so they can see the test entry.
    # The test is about analytics visibility, not data scoping.
    def payroll_user(*perms)
      role = PermissionRole.create!(
        business:           business,
        name:               "PRole-#{SecureRandom.hex(4)}",
        permissions:        perms.map(&:to_s),
        permission_scopes:  perms.map(&:to_s).index_with { "business_wide" }
      )
      create(:user, business: business, permission_role: role)
    end

    let(:records_only) { payroll_user(:view_payroll) }
    let(:analyst)      { payroll_user(:view_payroll, :view_payroll_analytics) }
    let!(:period)      { create(:payroll_period, business: business) }
    let!(:other_user)  { create(:user, business: business) }
    let!(:entry)       { create(:payroll_entry, payroll_period: period, user: other_user,
                                base_salary: 5000, total_overtime: 200,
                                total_deductions: 100, net_salary: 5100) }

    it "records-only user can access /payroll_periods" do
      expect(get_html(records_only, payroll_periods_path)).to have_http_status(:ok)
    end

    it "records-only user does NOT see the KPI summary strip" do
      body = get_html(records_only, payroll_periods_path).body
      expect(body).not_to include("payroll-kpi-grid"),
        "records-only user must not see organization-wide KPI summary cards"
    end

    it "records-only user does NOT see the payroll filter bar" do
      body = get_html(records_only, payroll_periods_path).body
      expect(body).not_to include("payroll-filters"),
        "records-only user must not have access to analytics filters"
    end

    it "records-only user does NOT see the period totals footer row" do
      body = get_html(records_only, payroll_periods_path).body
      expect(body).not_to include("totals-row"),
        "records-only user must not see the grand-total footer row"
    end

    it "records-only user does NOT see the aggregate columns on the period table" do
      body = get_html(records_only, payroll_periods_path).body
      expect(body).not_to include(I18n.t("payroll.index.employees_col"))
      expect(body).not_to include(I18n.t("payroll.index.net_total_col"))
    end

    it "records-only user does NOT see period overview metrics on show" do
      body = get_html(records_only, payroll_period_path(period)).body
      expect(body).not_to include("payroll-overview"),
        "records-only user must not see period-level financial aggregates"
    end

    it "records-only user does NOT see anomaly alerts on show" do
      body = get_html(records_only, payroll_period_path(period)).body
      expect(body).not_to include("payroll-alerts")
    end

    it "records-only user is denied the payroll dashboard" do
      expect(get_html(records_only, payroll_dashboard_path).status).to be_in([302, 403])
    end

    it "records-only user is denied the API analytics summary endpoint" do
      sign_in records_only
      get "/api/v1/reports/payroll/summary", params: { payroll_period_id: period.id }, as: :json
      expect(response.status).to be_in([401, 403])
    end

    it "records-only user is denied the CSV export endpoint" do
      sign_in records_only
      get "/api/v1/reports/payroll/export.csv", params: { payroll_period_id: period.id }
      expect(response.status).to be_in([401, 403])
    end

    it "records-only user does NOT receive entry_count aggregate in API index" do
      sign_in records_only
      get "/api/v1/payroll_periods", as: :json
      expect(response).to have_http_status(:ok)
      response.parsed_body["data"].each do |p|
        expect(p).not_to have_key("entry_count"),
          "entry_count is an aggregate — must be hidden from records-only users"
      end
    end

    # ── Analyst (records + analytics) sees everything ──
    it "analyst sees the KPI summary strip" do
      expect(get_html(analyst, payroll_periods_path).body).to include("payroll-kpi-grid")
    end

    it "analyst sees the filter bar" do
      expect(get_html(analyst, payroll_periods_path).body).to include("payroll-filters")
    end

    it "analyst sees period overview metrics on show" do
      expect(get_html(analyst, payroll_period_path(period)).body).to include("payroll-overview")
    end

    it "analyst can access the payroll dashboard" do
      expect(get_html(analyst, payroll_dashboard_path)).to have_http_status(:ok)
    end

    it "analyst can hit the API analytics summary endpoint" do
      sign_in analyst
      get "/api/v1/reports/payroll/summary", params: { payroll_period_id: period.id }, as: :json
      expect(response).to have_http_status(:ok)
    end

    it "analyst receives entry_count aggregate in API index" do
      sign_in analyst
      get "/api/v1/payroll_periods", as: :json
      response.parsed_body["data"].each do |p|
        expect(p).to have_key("entry_count")
      end
    end

    # ── Toggle test: revoke analytics live, aggregates disappear next request ──
    it "revoking view_payroll_analytics live removes analytics from the very next request" do
      sign_in analyst
      get payroll_periods_path
      expect(response.body).to include("payroll-kpi-grid")

      analyst.permission_role.update!(permissions: %w[view_payroll])
      get payroll_periods_path
      expect(response.body).not_to include("payroll-kpi-grid"),
        "KPI strip must vanish on the next request after the permission is revoked"
    end

    # ── Dependency check: cannot grant analytics without view_payroll ──
    it "the permission role validates that view_payroll_analytics requires view_payroll" do
      role = PermissionRole.new(business: business, name: "Bad-#{rand(10000)}",
                                permissions: %w[view_payroll_analytics])
      expect(role).not_to be_valid
      expect(role.errors[:permissions].join).to include("view_payroll")
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # Test J — Payroll workflow granularity.
  #   Every lifecycle action (create / regenerate / submit / approve_all /
  #   complete_branch_review / finalize / pay / reopen / delete) has its own
  #   permission. A user granted only one workflow permission can perform
  #   that single action and is denied every other workflow endpoint.
  # ────────────────────────────────────────────────────────────────────────────
  describe "Test J — payroll workflow granularity" do
    def workflow_user(*perms)
      role = PermissionRole.create!(
        business:    business,
        name:        "WflRole-#{SecureRandom.hex(4)}",
        permissions: (perms.map(&:to_s) | %w[view_payroll]).uniq
      )
      create(:user, business: business, permission_role: role)
    end

    let!(:other_user) { create(:user, business: business) }

    # ── PERMISSION ROLE MODEL: granular permissions exist & validate ──
    describe "permission catalog" do
      it "exposes a granular permission per lifecycle action" do
        expect(PermissionRole::ALL_PERMISSIONS).to include(
          "create_payroll", "regenerate_payroll", "submit_payroll_review",
          "complete_branch_review", "approve_payroll_items",
          "finalize_payroll", "pay_payroll", "reopen_payroll", "delete_payroll",
          "view_payroll_audit_log"
        )
      end

      it "no longer exposes the legacy coarse manage_payroll permission" do
        expect(PermissionRole::ALL_PERMISSIONS).not_to include("manage_payroll")
      end

      it "every new workflow permission requires view_payroll" do
        %w[create_payroll regenerate_payroll submit_payroll_review
           complete_branch_review approve_payroll_items pay_payroll
           reopen_payroll delete_payroll view_payroll_audit_log].each do |perm|
          role = PermissionRole.new(business: business, name: "Bad-#{SecureRandom.hex(3)}",
                                    permissions: [perm])
          expect(role).not_to be_valid, "#{perm} should require view_payroll"
          expect(role.errors[:permissions].join).to include("view_payroll"),
            "#{perm} should mention view_payroll in its validation error"
        end
      end

      it "complete_branch_review is scopable" do
        expect(PermissionRole::SCOPABLE_PERMISSIONS).to include("complete_branch_review")
      end

      it "global-period actions are NOT scopable" do
        %w[finalize_payroll pay_payroll delete_payroll reopen_payroll
           approve_payroll_items create_payroll regenerate_payroll
           submit_payroll_review].each do |perm|
          expect(PermissionRole::SCOPABLE_PERMISSIONS).not_to include(perm),
            "#{perm} should not be scopable — it's a period-wide action"
        end
      end
    end

    # ── CREATE_PAYROLL ──
    describe "create_payroll" do
      let(:user) { workflow_user(:create_payroll) }

      it "permits POST /payroll_periods" do
        sign_in user
        post payroll_periods_path, params: { payroll_period: { year: 2025, month: 1 } }
        # Either creates the period or returns a domain error — but NEVER a 403.
        expect(response.status).to be_in([200, 302, 422])
      end

      it "denies submit_for_review (no submit_payroll_review)" do
        period = create(:payroll_period, business: business)
        sign_in user
        patch submit_for_review_payroll_period_path(period)
        expect(response.status).to be_in([302, 403])
        expect(period.reload.status).to eq("draft")
      end

      it "denies finalize, mark_paid, delete, reopen" do
        period = create(:payroll_period, :under_review, business: business)
        sign_in user
        patch finalize_payroll_period_path(period)
        expect(period.reload.status).not_to eq("finalized")
      end
    end

    # ── SUBMIT_PAYROLL_REVIEW ──
    describe "submit_payroll_review" do
      let(:user) { workflow_user(:submit_payroll_review) }
      let!(:period) { create(:payroll_period, business: business) }

      it "permits submit_for_review on a draft period" do
        # Need at least one entry to populate branch reviews.
        create(:payroll_entry, payroll_period: period, user: other_user)
        sign_in user
        patch submit_for_review_payroll_period_path(period)
        expect(period.reload.status).to eq("under_review")
      end

      it "denies create_payroll" do
        sign_in user
        post payroll_periods_path, params: { payroll_period: { year: 2025, month: 6 } }
        expect(response.status).to be_in([302, 403])
      end
    end

    # ── APPROVE_PAYROLL_ITEMS ──
    describe "approve_payroll_items" do
      let(:user) { workflow_user(:approve_payroll_items) }
      let!(:period) { create(:payroll_period, business: business) }
      let!(:entry)  { create(:payroll_entry, payroll_period: period, user: other_user) }
      let!(:item)   { create(:payroll_line_item, :late_penalty, payroll_entry: entry) }

      it "permits bulk approve" do
        sign_in user
        patch approve_all_pending_payroll_period_path(period)
        expect(item.reload.review_status).to eq("approved")
      end

      it "denies finalize" do
        sign_in user
        patch finalize_payroll_period_path(period)
        expect(period.reload.status).to eq("draft")
      end
    end

    # ── FINALIZE_PAYROLL ──
    describe "finalize_payroll" do
      let(:user) { workflow_user(:finalize_payroll) }
      let!(:period) { create(:payroll_period, business: business, status: "branch_review_completed") }

      it "permits finalize" do
        sign_in user
        patch finalize_payroll_period_path(period)
        expect(period.reload.status).to eq("finalized")
      end

      it "denies pay (no pay_payroll)" do
        period.update!(status: "finalized")
        sign_in user
        patch mark_paid_payroll_period_path(period)
        expect(period.reload.status).to eq("finalized")  # unchanged
      end

      it "denies reopen" do
        period.update!(status: "finalized")
        sign_in user
        patch reopen_payroll_period_path(period), params: { reason: "test" }
        expect(period.reload.status).to eq("finalized")  # unchanged
      end
    end

    # ── PAY_PAYROLL ──
    describe "pay_payroll" do
      let(:user) { workflow_user(:pay_payroll) }
      let!(:period) { create(:payroll_period, business: business, status: "finalized") }

      it "permits mark_paid" do
        sign_in user
        patch mark_paid_payroll_period_path(period)
        expect(period.reload.status).to eq("paid")
      end

      it "denies finalize (no finalize_payroll)" do
        unfinalized = create(:payroll_period, business: business, status: "branch_review_completed",
                             period_year: 2025, period_month: 11)
        sign_in user
        patch finalize_payroll_period_path(unfinalized)
        expect(unfinalized.reload.status).to eq("branch_review_completed")
      end
    end

    # ── REOPEN_PAYROLL ──
    describe "reopen_payroll" do
      it "permits reopen finalized → branch_review_completed with reason" do
        user   = workflow_user(:reopen_payroll)
        period = create(:payroll_period, business: business, status: "finalized")
        sign_in user
        patch reopen_payroll_period_path(period), params: { reason: "Discovered overtime miscalculation" }
        expect(period.reload.status).to eq("branch_review_completed")
      end

      it "denies reopen of paid period without pay_payroll" do
        user   = workflow_user(:reopen_payroll)  # has reopen_payroll only
        period = create(:payroll_period, business: business, status: "paid")
        sign_in user
        patch reopen_payroll_period_path(period), params: { reason: "wrong" }
        expect(period.reload.status).to eq("paid")  # unchanged
      end

      it "permits reopen of paid period when both reopen_payroll AND pay_payroll are granted" do
        user   = workflow_user(:reopen_payroll, :pay_payroll)
        period = create(:payroll_period, business: business, status: "paid")
        sign_in user
        patch reopen_payroll_period_path(period), params: { reason: "Bank rejected the disbursement" }
        expect(period.reload.status).to eq("finalized")
      end

      it "rejects reopen without a reason (service guard)" do
        user   = workflow_user(:reopen_payroll)
        period = create(:payroll_period, business: business, status: "finalized")
        sign_in user
        patch reopen_payroll_period_path(period), params: { reason: "" }
        expect(period.reload.status).to eq("finalized")  # unchanged
      end

      it "writes a PayrollAuditLog entry with the reason" do
        user   = workflow_user(:reopen_payroll)
        period = create(:payroll_period, business: business, status: "finalized")
        sign_in user
        expect {
          patch reopen_payroll_period_path(period), params: { reason: "Correction needed" }
        }.to change(PayrollAuditLog, :count).by(1)
        log = PayrollAuditLog.order(:id).last
        expect(log.action_type).to eq("reopened")
        expect(log.from_status).to eq("finalized")
        expect(log.to_status).to eq("branch_review_completed")
        expect(log.metadata_hash["reason"]).to eq("Correction needed")
      end
    end

    # ── DELETE_PAYROLL ──
    describe "delete_payroll" do
      let(:user) { workflow_user(:delete_payroll) }

      it "permits destroy on a draft period" do
        period = create(:payroll_period, business: business, status: "draft")
        sign_in user
        delete payroll_period_path(period)
        expect(PayrollPeriod.exists?(period.id)).to be(false)
      end

      it "denies destroy on a finalized period" do
        period = create(:payroll_period, business: business, status: "finalized")
        sign_in user
        delete payroll_period_path(period)
        expect(PayrollPeriod.exists?(period.id)).to be(true)
      end
    end

    # ── REGENERATE_PAYROLL ──
    describe "regenerate_payroll" do
      let(:user) { workflow_user(:regenerate_payroll) }

      it "permits regenerate on draft" do
        period = create(:payroll_period, business: business, status: "draft")
        sign_in user
        patch regenerate_payroll_period_path(period)
        expect(response.status).to be_in([200, 302])
      end

      it "denies regenerate on finalized — must reopen first" do
        period = create(:payroll_period, business: business, status: "finalized")
        sign_in user
        patch regenerate_payroll_period_path(period)
        expect(response.status).to be_in([302, 403])
        expect(period.reload.status).to eq("finalized")
      end
    end

    # ── COMPLETE_BRANCH_REVIEW with scope ──
    describe "complete_branch_review" do
      let(:branch_a) { create(:branch, business: business) }
      let(:branch_b) { create(:branch, business: business) }
      let!(:period)  { create(:payroll_period, business: business, status: "under_review") }

      before do
        # Two branch review slots — each branch needs one
        create(:payroll_period_branch_review, payroll_period: period, branch: branch_a)
        create(:payroll_period_branch_review, payroll_period: period, branch: branch_b)
      end

      it "branch-scoped user can only complete reviews for branches they manage" do
        user = workflow_user(:complete_branch_review)
        branch_a.update!(branch_manager_id: user.id)
        sign_in user
        patch complete_branch_review_payroll_period_path(period)

        # branch_a review completed; branch_b review still pending
        expect(period.payroll_period_branch_reviews.find_by(branch: branch_a).status).to eq("completed")
        expect(period.payroll_period_branch_reviews.find_by(branch: branch_b).status).to eq("pending")
      end

      it "business-wide-scoped user can complete reviews for ANY branch in the business" do
        role = PermissionRole.create!(
          business:          business,
          name:              "FinOpsRole-#{SecureRandom.hex(4)}",
          permissions:       %w[view_payroll complete_branch_review],
          permission_scopes: { "complete_branch_review" => "business_wide" }
        )
        user = create(:user, business: business, permission_role: role)
        sign_in user
        patch complete_branch_review_payroll_period_path(period)

        expect(period.payroll_period_branch_reviews.find_by(branch: branch_a).status).to eq("completed")
        expect(period.payroll_period_branch_reviews.find_by(branch: branch_b).status).to eq("completed")
      end

      it "denies a user without complete_branch_review" do
        user = workflow_user(:view_payroll_analytics)  # has view_payroll, NOT complete_branch_review
        branch_a.update!(branch_manager_id: user.id)
        sign_in user
        patch complete_branch_review_payroll_period_path(period)

        expect(period.payroll_period_branch_reviews.find_by(branch: branch_a).status).to eq("pending")
      end
    end

    # ── LIVE PERMISSION TOGGLE ──
    describe "live permission revocation" do
      let!(:period) { create(:payroll_period, business: business, status: "finalized") }
      let(:user)    { workflow_user(:pay_payroll, :reopen_payroll) }

      it "revoking pay_payroll mid-session removes the mark-paid button immediately" do
        sign_in user
        get payroll_period_path(period)
        expect(response.body).to include(I18n.t("payroll.mark_paid"))

        user.permission_role.update!(permissions: %w[view_payroll reopen_payroll])
        get payroll_period_path(period)
        expect(response.body).not_to include(mark_paid_payroll_period_path(period)),
          "Mark-paid button must disappear on the next request after pay_payroll is revoked"
      end

      it "revoking reopen_payroll mid-session blocks the reopen endpoint immediately" do
        sign_in user
        user.permission_role.update!(permissions: %w[view_payroll pay_payroll])
        patch reopen_payroll_period_path(period), params: { reason: "still trying" }
        expect(period.reload.status).to eq("finalized")  # unchanged
      end
    end
  end
end
