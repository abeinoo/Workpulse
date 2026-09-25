require "rails_helper"

# The DR index (and its export) is limited to the last 14 business days —
# today + the previous 13 — for users without full-history access
# (DailyReconciliationPolicy#view_full_reconciliation_history?, i.e.
# verify_daily_reconciliation or view_deposit_verification; owners always pass). Show/member actions are
# NOT affected: older records stay reachable by direct URL.
RSpec.describe "Finance::DailyReconciliations index — 14-day history window", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def make_dr(business_date)
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: business_date.in_time_zone(business.timezone) + 10.hours,
      closed_at: business_date.in_time_zone(business.timezone) + 22.hours,
      business_date: business_date
    )
  end

  # 25/09/2026 12:00 Riyadh → business day 25/09; window 12/09 .. 25/09.
  let(:now) { Time.find_zone("Asia/Riyadh").local(2026, 9, 25, 12) }
  around { |ex| travel_to(now) { ex.run } }

  let(:today) { BusinessDay.current(context: business) }

  let!(:dr_today)   { make_dr(today) }
  let!(:dr_13_ago)  { make_dr(today - 13) }
  let!(:dr_14_ago)  { make_dr(today - 14) }
  let!(:dr_40_ago)  { make_dr(today - 40) }

  let(:admin)    { user_with("view_daily_reconciliation", "verify_daily_reconciliation") }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:cashier)  { user_with("view_daily_reconciliation") }

  def listed_ids(params = {})
    get finance_daily_reconciliations_path(params)
    expect(response).to have_http_status(:ok)
    controller.instance_variable_get(:@reconciliations).map(&:id)
  end

  it "uses 12/09/2026 .. 25/09/2026 as the window on 25/09/2026" do
    expect(today).to eq(Date.new(2026, 9, 25))
    expect(dr_13_ago.business_date).to eq(Date.new(2026, 9, 12))
    expect(dr_14_ago.business_date).to eq(Date.new(2026, 9, 11))
  end

  describe "A. admin (verify_daily_reconciliation)" do
    before { sign_in admin }

    it "sees today, 13 days ago, and 14+ days ago" do
      expect(listed_ids).to include(dr_today.id, dr_13_ago.id, dr_14_ago.id, dr_40_ago.id)
    end

    it "can filter into old history" do
      ids = listed_ids(from: (today - 45).iso8601, to: (today - 30).iso8601)
      expect(ids).to eq([ dr_40_ago.id ])
    end
  end

  describe "A. deposit-verification (finance) user" do
    before { sign_in user_with("view_daily_reconciliation", "view_deposit_verification") }

    it "sees the full history" do
      expect(listed_ids).to include(dr_today.id, dr_13_ago.id, dr_14_ago.id, dr_40_ago.id)
    end
  end

  describe "A. business owner" do
    before { sign_in owner }

    it "sees the full history" do
      expect(listed_ids).to include(dr_today.id, dr_13_ago.id, dr_14_ago.id, dr_40_ago.id)
    end
  end

  describe "B. normal user (view_daily_reconciliation only)" do
    before { sign_in cashier }

    it "sees today and 13 days ago, but nothing 14+ days old" do
      ids = listed_ids
      expect(ids).to include(dr_today.id, dr_13_ago.id)
      expect(ids).not_to include(dr_14_ago.id, dr_40_ago.id)
    end

    it "never renders links to out-of-window records" do
      get finance_daily_reconciliations_path
      [ dr_14_ago, dr_40_ago ].each do |dr|
        expect(response.body).not_to match(%r{/finance/daily_reconciliations/#{dr.id}(?!\d)})
      end
      expect(response.body).to match(%r{/finance/daily_reconciliations/#{dr_today.id}(?!\d)})
    end

    it "cannot widen the window with date filters" do
      expect(listed_ids(from: (today - 60).iso8601, to: today.iso8601)).not_to include(dr_14_ago.id, dr_40_ago.id)
      expect(listed_ids(from: (today - 45).iso8601, to: (today - 30).iso8601)).to be_empty
      expect(listed_ids(to: (today - 14).iso8601)).to be_empty
    end

    it "cannot widen the window with status, branch, or unknown/pagination params" do
      [
        { status: "waiting_deposit" },
        { branch_id: branch.id },
        { page: 2 }, { per_page: 1000 }, { limit: 1000 }, { all: 1 }, { days: 365 }
      ].each do |params|
        expect(listed_ids(params)).not_to include(dr_14_ago.id, dr_40_ago.id), "leaked with #{params.inspect}"
      end
    end

    it "does not offer a branch whose only DRs are out of the window" do
      old_branch = create(:branch, business: business, name: "Old Only Branch")
      DailyReconciliation.create!(branch: old_branch, business: business, state: "closed",
                                  opened_at: 30.days.ago, closed_at: 30.days.ago + 1.hour,
                                  business_date: today - 30)
      get finance_daily_reconciliations_path
      expect(controller.instance_variable_get(:@accessible_branches)).not_to include(old_branch)
    end

    it "cannot export out-of-window records, by filter or by ids[]" do
      get export_finance_daily_reconciliations_path(ids: [ dr_40_ago.id, dr_today.id ])
      expect(response.body).to include(dr_today.business_date.iso8601)
      expect(response.body).not_to include(dr_40_ago.business_date.iso8601)

      get export_finance_daily_reconciliations_path(from: (today - 45).iso8601, to: (today - 30).iso8601)
      expect(response.body).not_to include(dr_40_ago.business_date.iso8601)
    end
  end

  describe "C. show page for old records is unchanged" do
    it "a normal user can still open an out-of-window record directly" do
      sign_in cashier
      get finance_daily_reconciliation_path(dr_40_ago)
      expect(response).to have_http_status(:ok)
    end

    it "an admin can still open an out-of-window record directly" do
      sign_in admin
      get finance_daily_reconciliation_path(dr_40_ago)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "business-day boundary (timezone + start hour)" do
    # 03:00 Riyadh on 25/09 with a 06:00 start hour is still business day
    # 24/09 → window 11/09 .. 24/09 (calendar-day logic would give 12/09 .. 25/09).
    let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6) }
    let(:now)      { Time.find_zone("Asia/Riyadh").local(2026, 9, 25, 3) }

    it "keys the window on the business day, not the calendar day" do
      expect(today).to eq(Date.new(2026, 9, 24))
      expect(dr_13_ago.business_date).to eq(Date.new(2026, 9, 11))
      expect(dr_14_ago.business_date).to eq(Date.new(2026, 9, 10))

      sign_in cashier
      ids = listed_ids
      expect(ids).to include(dr_today.id, dr_13_ago.id)
      expect(ids).not_to include(dr_14_ago.id, dr_40_ago.id)
    end
  end
end
