require "rails_helper"

RSpec.describe "Finance::DailyReconciliations show — Previous/Next Day navigation", type: :request do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:branch_b)  { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer) { user_with("view_daily_reconciliation") }

  def make_dr(branch:, business_date:)
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: business_date
    )
  end

  it "links to the nearest earlier and later DR for the same branch, by business_date" do
    two_days_ago = make_dr(branch: branch, business_date: Date.current - 2)
    yesterday    = make_dr(branch: branch, business_date: Date.current - 1)
    today        = make_dr(branch: branch, business_date: Date.current)
    tomorrow     = make_dr(branch: branch, business_date: Date.current + 1)

    sign_in viewer
    get finance_daily_reconciliation_path(today)

    expect(response.body).to include(finance_daily_reconciliation_path(yesterday))
    expect(response.body).to include(finance_daily_reconciliation_path(tomorrow))
    expect(response.body).not_to include(finance_daily_reconciliation_path(two_days_ago))
  end

  it "disables Previous when there is no earlier DR for the branch" do
    today    = make_dr(branch: branch, business_date: Date.current)
    tomorrow = make_dr(branch: branch, business_date: Date.current + 1)

    sign_in viewer
    get finance_daily_reconciliation_path(today)

    expect(response.body).to include(finance_daily_reconciliation_path(tomorrow))
    doc = Nokogiri::HTML(response.body)
    prev_link = doc.at_css("a[title='#{I18n.t('finance.daily_reconciliations.show.nav_previous_day')}']")
    expect(prev_link).to be_nil
    expect(doc.at_css("span[aria-disabled='true'][title='#{I18n.t('finance.daily_reconciliations.show.nav_previous_day')}']")).to be_present
  end

  it "disables Next when there is no later DR for the branch" do
    yesterday = make_dr(branch: branch, business_date: Date.current - 1)
    today     = make_dr(branch: branch, business_date: Date.current)

    sign_in viewer
    get finance_daily_reconciliation_path(today)

    expect(response.body).to include(finance_daily_reconciliation_path(yesterday))
    doc = Nokogiri::HTML(response.body)
    next_link = doc.at_css("a[title='#{I18n.t('finance.daily_reconciliations.show.nav_next_day')}']")
    expect(next_link).to be_nil
    expect(doc.at_css("span[aria-disabled='true'][title='#{I18n.t('finance.daily_reconciliations.show.nav_next_day')}']")).to be_present
  end

  it "never crosses into another branch's DRs, even if their business_date would otherwise be adjacent" do
    today_branch_a     = make_dr(branch: branch,   business_date: Date.current)
    yesterday_branch_b = make_dr(branch: branch_b, business_date: Date.current - 1)
    tomorrow_branch_b  = make_dr(branch: branch_b, business_date: Date.current + 1)

    sign_in viewer
    get finance_daily_reconciliation_path(today_branch_a)

    expect(response.body).not_to include(finance_daily_reconciliation_path(yesterday_branch_b))
    expect(response.body).not_to include(finance_daily_reconciliation_path(tomorrow_branch_b))
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("span[aria-disabled='true'][title='#{I18n.t('finance.daily_reconciliations.show.nav_previous_day')}']")).to be_present
    expect(doc.at_css("span[aria-disabled='true'][title='#{I18n.t('finance.daily_reconciliations.show.nav_next_day')}']")).to be_present
  end

  it "respects the policy scope — a branch-scoped user only navigates within branches they're authorized to see" do
    scoped_role = business.permission_roles.create!(
      name: "Branch-#{SecureRandom.hex(3)}",
      permissions: %w[view_daily_reconciliation],
      permission_scopes: { "view_daily_reconciliation" => "branch" }
    )
    scoped_user = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, scoped_role.id) }
    create(:shift_assignment, user: scoped_user, branch: branch, effective_from: Date.current - 30)

    today    = make_dr(branch: branch, business_date: Date.current)
    tomorrow = make_dr(branch: branch, business_date: Date.current + 1)

    sign_in scoped_user
    get finance_daily_reconciliation_path(today)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(finance_daily_reconciliation_path(tomorrow))
  end

  # CSS flexbox reverses which physical side the first DOM child renders on
  # when dir="rtl" (first child = right edge, not left) — so "correct DOM
  # order" is direction-dependent. These specs assert the actual physical
  # outcome (right = Next, left = Previous) in both directions, not just
  # that both links are present somewhere on the page.
  describe "physical left/right position stays right=Next, left=Previous in both directions" do
    it "in LTR (English): DOM order is [Previous, Next], which renders left=Previous, right=Next" do
      yesterday = make_dr(branch: branch, business_date: Date.current - 1)
      today     = make_dr(branch: branch, business_date: Date.current)
      tomorrow  = make_dr(branch: branch, business_date: Date.current + 1)
      viewer.update_column(:preferred_locale, "en") if viewer.respond_to?(:preferred_locale)

      sign_in viewer
      get finance_daily_reconciliation_path(today)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("html")["dir"]).to eq("ltr")
      links = doc.css("h1.page-title a[href]")
      expect(links.map { |a| a["href"] }).to eq(
        [ finance_daily_reconciliation_path(yesterday), finance_daily_reconciliation_path(tomorrow) ]
      )
    end

    it "in RTL (Arabic): DOM order is [Next, Previous], which renders right=Next, left=Previous" do
      yesterday = make_dr(branch: branch, business_date: Date.current - 1)
      today     = make_dr(branch: branch, business_date: Date.current)
      tomorrow  = make_dr(branch: branch, business_date: Date.current + 1)
      viewer.update_column(:preferred_locale, "ar") if viewer.respond_to?(:preferred_locale)

      sign_in viewer
      get finance_daily_reconciliation_path(today)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("html")["dir"]).to eq("rtl")
      links = doc.css("h1.page-title a[href]")
      expect(links.map { |a| a["href"] }).to eq(
        [ finance_daily_reconciliation_path(tomorrow), finance_daily_reconciliation_path(yesterday) ]
      )
    end
  end

  it "orders adjacency by business_date, not by id/creation order" do
    # Create the "yesterday" DR AFTER "today" so id order is reversed
    # relative to business_date order — proves adjacency is date-driven.
    today     = make_dr(branch: branch, business_date: Date.current)
    yesterday = make_dr(branch: branch, business_date: Date.current - 1)

    expect(yesterday.id).to be > today.id

    sign_in viewer
    get finance_daily_reconciliation_path(today)

    expect(response.body).to include(finance_daily_reconciliation_path(yesterday))
  end
end
