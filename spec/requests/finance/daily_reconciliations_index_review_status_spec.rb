require "rails_helper"

RSpec.describe "Finance::DailyReconciliations index — Waiting for Branch Review status", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:manager)  { create(:user, :owner, business: business) }

  def make_dr(state:, reviewed: false, business_date: Date.current)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: state,
      opened_at: 1.hour.ago, closed_at: (Time.current if state != "open"), business_date: business_date,
      reviewed_by: (manager if reviewed), reviewed_at: (1.minute.ago if reviewed)
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: manager.id) unless dr.till_session
    dr
  end

  before { sign_in manager }

  it "shows the Waiting for Branch Review badge for a closed, unreviewed DR" do
    make_dr(state: "closed", reviewed: false)

    get finance_daily_reconciliations_path

    expect(response.body).to include("Waiting for Branch Review")
  end

  it "shows Awaiting Deposit instead, once the DR has been reviewed" do
    make_dr(state: "closed", reviewed: true)

    get finance_daily_reconciliations_path

    expect(response.body).to include("Awaiting Deposit")
    expect(response.body).not_to include("Waiting for Branch Review</span>")
  end

  it "counts unreviewed closed DRs in the Waiting for Branch Review summary card" do
    make_dr(state: "closed", reviewed: false, business_date: Date.current)
    make_dr(state: "closed", reviewed: false, business_date: Date.yesterday)
    make_dr(state: "closed", reviewed: true, business_date: 2.days.ago)

    get finance_daily_reconciliations_path

    doc = Nokogiri::HTML(response.body)
    label = doc.at_xpath("//p[contains(., 'Waiting for Branch Review') and contains(@class, 'stat-card__label')]")
    value = label.parent.at_css(".stat-card__value").text.strip
    expect(value).to eq("2")
  end
end
