require "rails_helper"

# OpeningFloatsController resolves the DR itself (the form posts no DR id).
# It must pick only the CURRENT business day's closed DR — the same rule as
# the show page's "Leave opening float" button — never merely the latest
# closed one, which can be a past date closed after today's.
RSpec.describe "OpeningFloats#create — DR selection", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:today)    { BusinessDay.current(context: business) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:cashier) do
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: %w[close_till_session])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  before do
    create(:shift_assignment, business: business, user: cashier, branch: branch,
           shift: create(:shift, :fixed_time, business: business),
           effective_from: Date.new(2026, 1, 1), effective_to: nil)
    sign_in cashier
  end

  def closed_dr(date, closed_at:)
    DailyReconciliation.create_for!(branch: branch, business_date: date).tap do |dr|
      dr.update!(state: "closed", closed_at: closed_at)
    end
  end

  def post_float
    post opening_floats_path,
         params: { opening_float: { amounts: { cash_pm.id.to_s => { collected_amount: "300", refund_amount: "0" } } } }
  end

  it "leaves the float from today's DR even when a past-dated DR was closed after it" do
    today_dr = closed_dr(today, closed_at: 2.hours.ago)
    past_dr  = closed_dr(today - 2.days, closed_at: 1.minute.ago)

    post_float

    expect(response).to redirect_to(finance_daily_reconciliation_path(today_dr))
    expect(today_dr.till_handovers.where(opening_float_declaration: true).count).to eq(1)
    expect(past_dr.till_handovers.where(opening_float_declaration: true)).to be_empty
    expect(DailyReconciliation.waiting_for(branch).business_date).to eq(today + 1)
  end

  it "cannot be triggered for a past reconciliation when today's has none closed" do
    past_dr = closed_dr(today - 2.days, closed_at: 1.minute.ago)

    expect { post_float }.not_to change(TillHandover, :count)

    expect(response).to redirect_to(finance_daily_reconciliations_path)
    expect(flash[:alert]).to eq(I18n.t("opening_floats.errors.no_closed_session"))
    expect(past_dr.till_handovers.where(opening_float_declaration: true)).to be_empty
    expect(DailyReconciliation.waiting_for(branch)).to be_nil
  end
end

# The cashier's branch is resolved for the BUSINESS day, not Date.current
# (UTC calendar). A salon open past midnight closes and leaves its float in
# the last hour before rollover; with a branch transfer at that boundary,
# Date.current would resolve the NEXT day's branch.
RSpec.describe "OpeningFloats#create — branch resolved for the business day near rollover", type: :request do
  # Cairo is UTC+2 in November; the business day rolls over at 03:00 local.
  let(:business)     { create(:business, timezone: "Africa/Cairo", business_day_start_hour: 3) }
  let(:branch)       { create(:branch, business: business, name: "Nasr City") }
  let(:other_branch) { create(:branch, business: business, name: "Shoubra") }
  let(:nov3)         { Date.new(2026, 11, 3) }
  let!(:cash_pm)     { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:cashier) do
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: %w[close_till_session])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def closed_dr(at_branch)
    DailyReconciliation.create_for!(branch: at_branch, business_date: nov3).tap do |dr|
      dr.update!(state: "closed", closed_at: Time.current)
    end
  end

  it "at 02:30 Cairo (already Nov 4 in UTC) leaves the float at the Nov 3 branch, not the branch starting Nov 4" do
    shift = create(:shift, :fixed_time, business: business)
    create(:shift_assignment, business: business, user: cashier, branch: branch, shift: shift,
           effective_from: Date.new(2026, 1, 1), effective_to: nov3)
    create(:shift_assignment, business: business, user: cashier, branch: other_branch, shift: shift,
           effective_from: nov3 + 1.day, effective_to: nil)

    travel_to Time.utc(2026, 11, 4, 0, 30) do
      expect(Date.current).to eq(nov3 + 1.day)
      expect(BusinessDay.current(context: business)).to eq(nov3)

      nasr_dr    = closed_dr(branch)
      shoubra_dr = closed_dr(other_branch)
      sign_in cashier

      post opening_floats_path,
           params: { opening_float: { amounts: { cash_pm.id.to_s => { collected_amount: "300", refund_amount: "0" } } } }

      expect(response).to redirect_to(finance_daily_reconciliation_path(nasr_dr))
      expect(nasr_dr.till_handovers.where(opening_float_declaration: true).count).to eq(1)
      expect(shoubra_dr.till_handovers.where(opening_float_declaration: true)).to be_empty
      expect(DailyReconciliation.waiting_for(branch).business_date).to eq(nov3 + 1.day)
      expect(DailyReconciliation.waiting_for(other_branch)).to be_nil
    end
  end
end
