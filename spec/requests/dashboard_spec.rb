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

      it "shows the upcoming shifts section" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("dashboard.upcoming_shifts.title"))
        expect(response.body).to include(shift.name)
      end
    end

    context "when there are no future shift assignments" do
      it "does not show the upcoming shifts section" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(I18n.t("dashboard.upcoming_shifts.title"))
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Month stats section always renders
  # ──────────────────────────────────────────────────────────────
  describe "GET / (employee dashboard) — month stats" do
    it "always renders the month stats section" do
      get root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("dashboard.month_stats.title"))
    end

    context "with attendance records this month" do
      let!(:present_record) do
        create(:attendance_record, :checked_out,
               user: employee, branch: branch,
               date: Date.current, work_date: Date.current)
      end

      it "counts days attended" do
        get root_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("dashboard.month_stats.present"))
      end
    end
  end
end
