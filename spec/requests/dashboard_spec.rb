require "rails_helper"

RSpec.describe "Dashboard", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }

  before { sign_in employee }

  # ──────────────────────────────────────────────────────────────
  # Payroll visibility — employees must never see draft payroll
  # ──────────────────────────────────────────────────────────────
  describe "GET / (employee dashboard) — payroll visibility" do
    context "when the only payroll entry is in a draft period" do
      let!(:draft_period) { create(:payroll_period, business: business) }
      let!(:draft_entry)  { create(:payroll_entry, payroll_period: draft_period, user: employee) }

      it "does not render the payroll snapshot card" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(draft_period.period_label)
      end
    end

    context "when the only payroll entry is in an under_review period" do
      let!(:review_period) { create(:payroll_period, :under_review, business: business) }
      let!(:review_entry)  { create(:payroll_entry, payroll_period: review_period, user: employee) }

      it "does not render the payroll snapshot card" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(review_period.period_label)
      end
    end

    context "when there is a finalized payroll period with an entry" do
      let!(:final_period) { create(:payroll_period, :finalized, business: business) }
      let!(:final_entry)  { create(:payroll_entry, payroll_period: final_period, user: employee) }

      it "renders the payroll snapshot card" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(final_period.period_label)
      end
    end

    context "when there is a paid payroll period with an entry" do
      let!(:paid_period) { create(:payroll_period, :paid, business: business) }
      let!(:paid_entry)  { create(:payroll_entry, payroll_period: paid_period, user: employee) }

      it "renders the payroll snapshot card" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(paid_period.period_label)
      end
    end

    context "when both draft and finalized entries exist" do
      let!(:draft_period) { create(:payroll_period, :draft,     business: business, period_year: 2026, period_month: 4) }
      let!(:final_period) { create(:payroll_period, :finalized, business: business, period_year: 2026, period_month: 3) }
      let!(:draft_entry)  { create(:payroll_entry, payroll_period: draft_period, user: employee) }
      let!(:final_entry)  { create(:payroll_entry, payroll_period: final_period, user: employee) }

      it "shows the finalized entry but not the draft period" do
        get root_path
        expect(response.body).to     include(final_period.period_label)
        expect(response.body).not_to include(draft_period.period_label)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Missing punch-out warning
  # ──────────────────────────────────────────────────────────────
  describe "GET / (employee dashboard) — missing punch-out warning" do
    context "when the employee has an incomplete check-in from yesterday" do
      let!(:yesterday_record) do
        create(:attendance_record, :for_yesterday,
               user: employee, branch: branch,
               status: "incomplete")
      end

      it "shows the missing clock-out alert" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("dashboard.missing_checkout.title"))
      end
    end

    context "when there is no incomplete record from yesterday" do
      it "does not show the missing clock-out alert" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(I18n.t("dashboard.missing_checkout.title"))
      end
    end

    context "when yesterday's record is complete (checked out)" do
      let!(:complete_record) do
        create(:attendance_record, :for_yesterday, :checked_out,
               user: employee, branch: branch)
      end

      it "does not show the missing clock-out alert" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(I18n.t("dashboard.missing_checkout.title"))
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Upcoming shifts section
  # ──────────────────────────────────────────────────────────────
  describe "GET / (employee dashboard) — upcoming shifts" do
    let(:shift) { create(:shift, :fixed_time, business: business) }

    context "when there are future shift assignments" do
      let!(:future_assignment) do
        create(:shift_assignment,
               user:           employee,
               shift:          shift,
               branch:         branch,
               effective_from: 3.days.from_now.to_date)
      end

      it "shows the schedule widget with the upcoming shift" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("dashboard.my_schedule.title"))
        expect(response.body).to include(shift.name)
      end
    end

    context "when there are no future shift assignments" do
      it "does not show the schedule widget" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(I18n.t("dashboard.my_schedule.title"))
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Shift progress bar — must never crash regardless of shift type
  # ──────────────────────────────────────────────────────────────
  describe "GET / (employee dashboard) — shift progress bar" do
    # Helper: create a current shift assignment + an open attendance record for today
    def setup_active_checkin(shift)
      assignment = create(:shift_assignment,
                          user:           employee,
                          shift:          shift,
                          branch:         branch,
                          effective_from: 1.year.ago.to_date)
      create(:attendance_record,
             user:             employee,
             branch:           branch,
             date:             Date.current,
             work_date:        Date.current,
             check_in_at:      2.hours.ago,
             status:           "incomplete",
             shift_assignment: assignment)
    end

    context "with a fixed-time shift (has start/end times)" do
      let(:fixed_shift) { create(:shift, :fixed_time, business: business) }

      it "renders the progress bar without crashing" do
        setup_active_checkin(fixed_shift)
        expect { get root_path }.not_to raise_error
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("shift-progress")
      end
    end

    context "with an overnight fixed-time shift" do
      let(:overnight_shift) { create(:shift, :overnight, business: business) }

      it "renders the progress bar without crashing" do
        setup_active_checkin(overnight_shift)
        expect { get root_path }.not_to raise_error
        expect(response).to have_http_status(:ok)
      end
    end

    context "with a flexible (hour_based) shift — nil start/end times" do
      let(:flexible_shift) { create(:shift, :hour_based, business: business) }

      it "does not crash and shows the flexible schedule label" do
        setup_active_checkin(flexible_shift)
        expect { get root_path }.not_to raise_error
        expect(response).to have_http_status(:ok)
        expect(response.body).to     include(I18n.t("dashboard.flexible_schedule"))
        expect(response.body).not_to include("shift-progress__bar")
      end
    end

    context "with a legacy shift that has nil times despite fixed_time type" do
      let(:legacy_shift) do
        # Bypass validation to simulate a legacy record with missing times
        shift = build(:shift, shift_type: :fixed_time, start_time: nil, end_time: nil,
                              business: business)
        shift.save!(validate: false)
        shift
      end

      it "does not crash and shows the flexible schedule label" do
        setup_active_checkin(legacy_shift)
        expect { get root_path }.not_to raise_error
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("dashboard.flexible_schedule"))
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Month stats widget — data-gated (hidden when no attendance context)
  # ──────────────────────────────────────────────────────────────
  describe "GET / (employee dashboard) — month stats" do
    context "with no attendance context (no shifts, no records)" do
      it "does not render an empty month stats card" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(I18n.t("dashboard.month_stats.title"))
      end
    end

    context "with attendance records this month" do
      let!(:present_record) do
        create(:attendance_record, :checked_out,
               user: employee, branch: branch,
               date: Date.current, work_date: Date.current)
      end

      it "renders the month stats widget and counts days attended" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("dashboard.month_stats.title"))
        expect(response.body).to include(I18n.t("dashboard.month_stats.present"))
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Composable dashboard — additive permission-based sections
  #
  # The dashboard is composed of independent sections, each gated by
  # permission (visibility) + relationship (scope). A user sees every
  # section they qualify for; personal widgets are universal.
  # ──────────────────────────────────────────────────────────────
  describe "GET / — composable sections" do
    # Section/widget markers (unique, stable strings rendered only by that area).
    let(:universal_marker) { I18n.t("dashboard.quick_actions.new_request") } # quick bar — always
    let(:month_marker)     { I18n.t("dashboard.month_stats.title") }
    let(:schedule_marker)  { I18n.t("dashboard.my_schedule.title") }
    let(:attendance_marker){ I18n.t("dashboard.not_checked_in") }
    let(:branch_marker)    { I18n.t("dashboard.sections.branch_management") }
    let(:area_marker)      { I18n.t("dashboard.area_manager.section_branch_health") }
    let(:payroll_marker)   { I18n.t("dashboard.accountant.generate_payroll_label") }
    let(:analytics_marker) { I18n.t("dashboard.sections.business_analytics") }

    let(:shift) { create(:shift, :fixed_time, business: business) }

    def future_shift_for(user)
      create(:shift_assignment,
             user:           user,
             shift:          shift,
             branch:         branch,
             effective_from: 3.days.from_now.to_date)
    end

    # 1. Employee only ──────────────────────────────────────────
    context "employee with no permissions and no shifts" do
      it "renders only the universal personal area, no management sections" do
        sign_in create(:user, business: business)
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to     include(universal_marker)
        # No empty/irrelevant widgets when there is no data.
        expect(response.body).not_to include(month_marker)
        expect(response.body).not_to include(schedule_marker)
        expect(response.body).not_to include(branch_marker)
        expect(response.body).not_to include(area_marker)
        expect(response.body).not_to include(payroll_marker)
        expect(response.body).not_to include(analytics_marker)
      end
    end

    # 2. Branch Manager with assigned shifts ────────────────────
    context "branch manager who also has an assigned shift" do
      let(:manager) { create(:user, :branch_manager, business: business) }

      it "renders the personal schedule plus the branch & area management it oversees" do
        future_shift_for(manager)
        sign_in manager
        get root_path

        expect(response).to have_http_status(:ok)
        # Personal schedule survives despite the management role (the Phase B fix).
        expect(response.body).to include(schedule_marker)
        # Management sections render additively for the branch they oversee.
        expect(response.body).to include(branch_marker)
        expect(response.body).to include(area_marker)
        # Not business-wide → no analytics.
        expect(response.body).not_to include(analytics_marker)
      end
    end

    # 3. Area Manager ───────────────────────────────────────────
    context "area manager (no shifts)" do
      let(:area_mgr) { create(:user, :area_manager, business: business) }

      it "renders the branch & area sections it oversees, and hides shift widgets" do
        sign_in area_mgr
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to     include(universal_marker)
        expect(response.body).to     include(area_marker)
        expect(response.body).to     include(branch_marker)
        expect(response.body).not_to include(analytics_marker)
        # No shifts → no schedule/attendance/month widgets.
        expect(response.body).not_to include(schedule_marker)
        expect(response.body).not_to include(month_marker)
      end
    end

    # 4. Accountant ─────────────────────────────────────────────
    context "accountant (no shifts)" do
      let(:accountant) { create(:user, :accountant, business: business) }

      it "renders the payroll section but no attendance management sections" do
        sign_in accountant
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to     include(universal_marker)
        expect(response.body).to     include(payroll_marker)
        expect(response.body).not_to include(branch_marker)
        expect(response.body).not_to include(area_marker)
        expect(response.body).not_to include(analytics_marker)
        expect(response.body).not_to include(schedule_marker)
      end
    end

    # 5. Owner ──────────────────────────────────────────────────
    context "owner (no shifts)" do
      let(:owner) { create(:user, :owner, business: business) }
      # Business-wide scope needs a branch + an employee to have data to show.
      let!(:a_branch)   { branch }
      let!(:an_employee) { create(:user, business: business) }

      it "renders the UNION of business-wide sections and hides shift widgets" do
        sign_in owner
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(universal_marker)
        # Business-wide permission ⇒ sees every section, no relationship needed.
        expect(response.body).to include(branch_marker)
        expect(response.body).to include(area_marker)
        expect(response.body).to include(analytics_marker)
        # Phase C: owners must NOT see attendance/schedule/month personal widgets.
        expect(response.body).not_to include(schedule_marker)
        expect(response.body).not_to include(attendance_marker)
        expect(response.body).not_to include(month_marker)
      end
    end

    # 6. Branch Manager + Payroll permissions ───────────────────
    context "branch manager who also has payroll permission" do
      let(:manager) { create(:user, :branch_manager, business: business) }

      it "renders both the branch management and payroll sections" do
        # The branch_manager trait already grants view_payroll.
        expect(manager.can?(:view_payroll)).to be(true)
        sign_in manager
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(branch_marker)
        expect(response.body).to include(payroll_marker)
      end
    end

    # 7. User with no shifts ────────────────────────────────────
    context "user with no shift assignments" do
      it "renders the dashboard without the schedule widget and does not crash" do
        sign_in create(:user, business: business)
        expect { get root_path }.not_to raise_error

        expect(response).to have_http_status(:ok)
        expect(response.body).to     include(universal_marker)
        expect(response.body).not_to include(schedule_marker)
      end
    end

    # 8. User with shifts but no management permissions ─────────
    context "plain employee who has shift assignments" do
      it "shows the schedule widget driven purely by assignment existence" do
        employee_with_shift = create(:user, business: business)
        future_shift_for(employee_with_shift)
        sign_in employee_with_shift
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to     include(schedule_marker)
        # Upcoming assignment also gives an attendance context → month widget shows.
        expect(response.body).to     include(month_marker)
        # No management sections without permissions.
        expect(response.body).not_to include(branch_marker)
        expect(response.body).not_to include(area_marker)
        expect(response.body).not_to include(payroll_marker)
        expect(response.body).not_to include(analytics_marker)
      end
    end

    # 9. Admin — business-wide permission, NO branch/area relationship ──
    # This is the regression target: previously the relationship/FK gates hid
    # these sections from a permission-holder with no assignment.
    context "admin with business-wide permissions but no relationship assignments" do
      let(:admin_role) do
        create(:permission_role, business: business,
               permissions: %w[view_attendance view_payroll view_requests approve_requests view_employees view_dashboard],
               permission_scopes: { "view_attendance" => "business_wide" })
      end
      let(:admin) { create(:user, business: business, permission_role: admin_role) }
      let!(:a_branch)    { branch }
      let!(:an_employee) { create(:user, business: business) }

      it "sees the UNION of all permitted sections without any relationship" do
        # Not a branch/area manager, not an owner.
        expect(admin.managed_branch_ids).to be_empty
        expect(admin.area_managed_branch_ids).to be_empty
        expect(admin.owner?).to be(false)

        sign_in admin
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(branch_marker)    # team / branch mgmt
        expect(response.body).to include(area_marker)       # branch health / alerts
        expect(response.body).to include(payroll_marker)    # payroll
        expect(response.body).to include(analytics_marker)  # business analytics
      end

      # Business analytics is gated by view_dashboard on top of business-wide
      # attendance (DashboardController#show_analytics_section?, b84dde3).
      it "does not see business analytics without view_dashboard, even with business-wide attendance" do
        admin_role.update!(permissions: admin_role.permissions - %w[view_dashboard])
        sign_in admin
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(area_marker)
        expect(response.body).not_to include(analytics_marker)
      end
    end

    # 10. Multi-role — branch manager + payroll + business-wide attendance ──
    context "multi-role user (branch manager + business-wide attendance + payroll)" do
      let(:multi_role) do
        create(:permission_role, business: business,
               permissions: %w[view_attendance view_payroll view_requests approve_requests view_shifts assign_shifts view_dashboard],
               permission_scopes: { "view_attendance" => "business_wide" })
      end
      let(:user) { create(:user, business: business, permission_role: multi_role) }
      let!(:a_branch)    { branch }
      let!(:an_employee) { create(:user, business: business) }

      it "renders every applicable section together" do
        future_shift_for(user)
        sign_in user
        get root_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(schedule_marker)   # personal (assignment-driven)
        expect(response.body).to include(branch_marker)
        expect(response.body).to include(area_marker)
        expect(response.body).to include(payroll_marker)
        expect(response.body).to include(analytics_marker)
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Phase C — Quick Actions bar (permission-driven) & empty-widget hiding
  # ──────────────────────────────────────────────────────────────
  describe "GET / — quick actions bar" do
    it "shows only universal shortcuts for a plain employee" do
      sign_in create(:user, business: business)
      get root_path

      expect(response.body).to     include(I18n.t("dashboard.quick_actions.new_request"))
      expect(response.body).to     include(I18n.t("dashboard.quick_actions.my_attendance"))
      # No management shortcuts without the permissions.
      expect(response.body).not_to include(I18n.t("dashboard.quick_actions.employees"))
      expect(response.body).not_to include(I18n.t("dashboard.quick_actions.approvals"))
    end

    it "shows permissioned shortcuts for an owner" do
      sign_in create(:user, :owner, business: business)
      get root_path

      expect(response.body).to include(I18n.t("dashboard.quick_actions.employees"))
      expect(response.body).to include(I18n.t("dashboard.quick_actions.approvals"))
      expect(response.body).to include(I18n.t("dashboard.quick_actions.payroll"))
    end

    it "shows the assign-shift shortcut only with :assign_shifts permission" do
      sign_in create(:user, :branch_manager, business: business)
      get root_path
      expect(response.body).to include(I18n.t("dashboard.quick_actions.assign_shift"))
    end
  end

  describe "GET / — empty widgets are hidden" do
    # Use widget-unique CSS hooks (the widgets' container classes) rather than
    # labels to avoid false matches against layout chrome.
    it "does not render the latest-payroll or requests widgets with no data" do
      sign_in create(:user, business: business)
      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("payroll-summary-card") # latest payroll
      expect(response.body).not_to include("request-row")          # my requests
    end

    context "when the data exists" do
      let!(:paid_period) { create(:payroll_period, :paid, business: business) }
      let!(:paid_entry)  { create(:payroll_entry, payroll_period: paid_period, user: employee) }

      it "renders the latest-payroll widget" do
        get root_path
        expect(response.body).to include("payroll-summary-card")
      end
    end
  end
end
