require "rails_helper"

# The business-day boundary around midnight (CLAUDE.md: the business day is not
# the calendar day; always BusinessDay / the business timezone, never
# Date.today / Date.current). For an Asia/Riyadh (UTC+3) business the UTC date
# and the business date differ every day from 21:00 to 24:00 UTC. These examples
# pin, at fixed instants on both sides of business midnight, that each screen and
# service whose specs used to compute UTC dates follows the business day — the
# behaviour those specs now assume (dashboard_spec, payroll/auto_generator_spec,
# api/v1/attendance_spec, custody_own_balance_responsive_spec).
RSpec.describe "Business-day boundary around midnight (Asia/Riyadh)", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }

  # 2026-10-22 21:00 UTC = 2026-10-23 00:00 in Riyadh.
  let(:just_before) { Time.utc(2026, 10, 22, 20, 59, 30) } # 23:59:30 on the 22nd (business)
  let(:just_after)  { Time.utc(2026, 10, 22, 21, 0, 30) }  # 00:00:30 on the 23rd (business), still the 22nd in UTC
  let(:late)        { Time.utc(2026, 10, 22, 22, 30) }     # 01:30 on the 23rd (business), still the 22nd in UTC

  it "BusinessDay rolls over at business midnight, not at UTC midnight" do
    expect(BusinessDay.current(context: business, now: just_before)).to eq(Date.new(2026, 10, 22))
    expect(BusinessDay.current(context: business, now: just_after)).to eq(Date.new(2026, 10, 23))
    travel_to(late) { expect([ Date.current, BusinessDay.current(context: business) ]).to eq([ Date.new(2026, 10, 22), Date.new(2026, 10, 23) ]) }
  end

  describe "employee dashboard — missing clock-out alert" do
    before { sign_in employee }

    def open_record(date)
      create(:attendance_record, user: employee, branch: branch, date: date, work_date: date,
                                 check_in_at: date.in_time_zone(business.timezone_object).change(hour: 9), status: "incomplete")
    end

    it "after business midnight, warns about the business yesterday (the 22nd), not the UTC yesterday" do
      travel_to(late) do
        open_record(Date.new(2026, 10, 22))
        get root_path
        expect(response.body).to include(I18n.t("dashboard.missing_checkout.title"))
      end
    end

    it "after business midnight, an open record of the UTC yesterday (the 21st) is not 'yesterday'" do
      travel_to(late) do
        open_record(Date.new(2026, 10, 21))
        get root_path
        expect(response.body).not_to include(I18n.t("dashboard.missing_checkout.title"))
      end
    end
  end

  describe "payroll auto-generation" do
    let(:actor) { create(:user, :super_admin, business: business) }

    def run = Payroll::AutoGenerator.call(business: business, actor: actor)

    it "after business midnight, generates on the business day (23), not the UTC day (22)" do
      travel_to(late) do
        business.update_column(:payroll_auto_generate_day, 23)
        expect(run).to be_success
        business.update_column(:payroll_auto_generate_day, 22)
        expect(run).to be_skipped
      end
    end

    it "just before business midnight, the business day is still 22" do
      travel_to(just_before) do
        business.update_column(:payroll_auto_generate_day, 22)
        expect(run).to be_success
      end
    end
  end

  describe "API check-in — the assignment in effect" do
    let(:shift) { create(:shift, :fixed_time, business: business) }

    before { sign_in employee }

    def check_in = post("/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json)

    it "after business midnight, an assignment starting on the business day (23rd) is in effect" do
      travel_to(late) do
        create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 10, 23))
        check_in
        expect(response).to have_http_status(:created)
        expect(AttendanceRecord.sole.work_date).to eq(Date.new(2026, 10, 23))
      end
    end

    it "after business midnight, an assignment that ended on the UTC day (22nd) is no longer in effect" do
      travel_to(late) do
        create(:shift_assignment, user: employee, branch: branch, shift: shift,
                                  effective_from: Date.new(2026, 10, 1), effective_to: Date.new(2026, 10, 22))
        check_in
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "own custody ledger — transaction dates" do
    let(:role) { create(:permission_role, business: business, permissions: %w[view_expenses create_expenses]) }
    let(:employee) { create(:user, business: business, permission_role: role) }
    let!(:account) { create(:custody_account, business: business, user: employee) }

    it "shows a transaction made after business midnight under the business date (October 23), not the UTC date" do
      travel_to(late) do
        account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 100)
        sign_in employee
        get finance_custody_accounts_path
        expect(response.body).to include(I18n.l(Date.new(2026, 10, 23), format: :long))
        expect(response.body).not_to include(I18n.l(Date.new(2026, 10, 22), format: :long))
      end
    end
  end
end
