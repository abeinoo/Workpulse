require "rails_helper"

RSpec.describe "Daily Reconciliations index — header branch selector", type: :request do
  let(:business)      { create(:business) }
  let(:sales_branch_a) { create(:branch, business: business, name: "Downtown Salon", branch_type: "sales") }
  let(:sales_branch_b) { create(:branch, business: business, name: "Uptown Salon", branch_type: "sales") }
  let(:warehouse)      { create(:branch, business: business, name: "Main Warehouse", branch_type: "warehouse") }
  let(:laundry)        { create(:branch, business: business, name: "Laundry Unit", branch_type: "laundry") }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:actor) { user_with("view_daily_reconciliation") }

  def make_dr(branch, business_date: Date.current)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: business_date.to_time + 10.hours, closed_at: business_date.to_time + 23.hours,
      business_date: business_date
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id)
    dr
  end

  before { sign_in actor }

  it "renders a header selector with a plain 'All Branches' default option (no 'Sales' wording)" do
    make_dr(sales_branch_a)
    make_dr(sales_branch_b)

    get finance_daily_reconciliations_path

    doc = Nokogiri::HTML(response.body)
    select = doc.at_css("select[name='branch_id']")
    expect(select).to be_present
    default_option = select.at_css("option[value='']")
    expect(default_option.text).to eq(I18n.t("finance.daily_reconciliations.index.filter_all_sales_branches"))
    expect(default_option.text).not_to include("Sales")
  end

  it "sorts branch options by name" do
    branch_z = create(:branch, business: business, name: "Zamalek Salon", branch_type: "sales")
    branch_a = create(:branch, business: business, name: "Aswan Salon", branch_type: "sales")
    make_dr(branch_z)
    make_dr(branch_a)

    get finance_daily_reconciliations_path

    doc = Nokogiri::HTML(response.body)
    labels = doc.at_css("select[name='branch_id']").css("option").map(&:text)
    # First option is the "All Branches" default; the rest must be alphabetical.
    expect(labels[1..]).to eq(labels[1..].sort)
  end

  it "only lists sales branches as options, never warehouse or laundry" do
    make_dr(sales_branch_a)
    make_dr(sales_branch_b)
    warehouse
    laundry

    get finance_daily_reconciliations_path

    doc = Nokogiri::HTML(response.body)
    select = doc.at_css("select[name='branch_id']")
    option_labels = select.css("option").map(&:text)

    expect(option_labels).to include(sales_branch_a.name)
    expect(option_labels).not_to include(warehouse.name)
    expect(option_labels).not_to include(laundry.name)
  end

  it "filters the reconciliation list, summary counters, and derived statuses by the selected branch" do
    dr_a = make_dr(sales_branch_a)
    dr_b = make_dr(sales_branch_b)

    get finance_daily_reconciliations_path(branch_id: sales_branch_a.id)

    body = response.body
    expect(body).to include(finance_daily_reconciliation_path(dr_a))
    expect(body).not_to include(finance_daily_reconciliation_path(dr_b))
  end

  it "shows every accessible branch's reconciliations when no branch is selected" do
    dr_a = make_dr(sales_branch_a)
    dr_b = make_dr(sales_branch_b)

    get finance_daily_reconciliations_path

    body = response.body
    expect(body).to include(finance_daily_reconciliation_path(dr_a))
    expect(body).to include(finance_daily_reconciliation_path(dr_b))
  end

  it "does not render the branch selector at all when only one sales branch is accessible" do
    make_dr(sales_branch_a)

    get finance_daily_reconciliations_path

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("select[name='branch_id']")).to be_nil
  end

  it "preserves the branch filter when the date/status filter form is submitted" do
    make_dr(sales_branch_a)
    make_dr(sales_branch_b)

    get finance_daily_reconciliations_path(branch_id: sales_branch_a.id)

    doc = Nokogiri::HTML(response.body)
    hidden = doc.at_css("input[type='hidden'][name='branch_id']")
    expect(hidden["value"]).to eq(sales_branch_a.id.to_s)
  end

  describe "sticky selection across navigation" do
    it "remembers the selected branch on a later request that carries no branch_id at all" do
      dr_a = make_dr(sales_branch_a)
      dr_b = make_dr(sales_branch_b)

      get finance_daily_reconciliations_path(branch_id: sales_branch_a.id)
      expect(response.body).to include(finance_daily_reconciliation_path(dr_a))
      expect(response.body).not_to include(finance_daily_reconciliation_path(dr_b))

      # Simulates returning to the index (or refreshing) via a link/URL with
      # no branch_id param — the previous explicit selection should still apply.
      get finance_daily_reconciliations_path
      expect(response.body).to include(finance_daily_reconciliation_path(dr_a))
      expect(response.body).not_to include(finance_daily_reconciliation_path(dr_b))
    end

    it "remembers an explicit switch back to All Branches (blank branch_id)" do
      dr_a = make_dr(sales_branch_a)
      dr_b = make_dr(sales_branch_b)

      get finance_daily_reconciliations_path(branch_id: sales_branch_a.id)
      get finance_daily_reconciliations_path(branch_id: "")

      doc = Nokogiri::HTML(response.body)
      select = doc.at_css("select[name='branch_id']")
      expect(select.at_css("option[selected]")).to be_nil # "All Branches" is selected by having no explicit selected option
      expect(response.body).to include(finance_daily_reconciliation_path(dr_a))
      expect(response.body).to include(finance_daily_reconciliation_path(dr_b))

      # And that "All Branches" choice itself is what's remembered next.
      get finance_daily_reconciliations_path
      expect(response.body).to include(finance_daily_reconciliation_path(dr_a))
      expect(response.body).to include(finance_daily_reconciliation_path(dr_b))
    end

    it "stays selected after opening a specific reconciliation and coming back to the index" do
      dr_a = make_dr(sales_branch_a)
      make_dr(sales_branch_b)

      get finance_daily_reconciliations_path(branch_id: sales_branch_a.id)
      get finance_daily_reconciliation_path(dr_a) # "opening a reconciliation"
      get finance_daily_reconciliations_path      # "returning to the index" with no query params

      doc = Nokogiri::HTML(response.body)
      selected = doc.at_css("select[name='branch_id'] option[selected]")
      expect(selected["value"]).to eq(sales_branch_a.id.to_s)
    end
  end

  describe "default branch selection priority (first visit — nothing remembered yet)" do
    it "auto-selects the sole accessible sales branch" do
      make_dr(sales_branch_a)

      get finance_daily_reconciliations_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("h1.page-title").text).to include(sales_branch_a.name)
    end

    it "falls back to the user's current shift-assignment branch when multiple branches are accessible and nothing is remembered" do
      make_dr(sales_branch_a)
      make_dr(sales_branch_b)
      create(:shift_assignment, business: business, user: actor, branch: sales_branch_b)

      get finance_daily_reconciliations_path

      doc = Nokogiri::HTML(response.body)
      selected = doc.at_css("select[name='branch_id'] option[selected]")
      expect(selected["value"]).to eq(sales_branch_b.id.to_s)
      expect(doc.at_css("h1.page-title").text).to include(sales_branch_b.name)
    end

    it "falls back to All Branches when multiple branches are accessible and there's no shift assignment" do
      make_dr(sales_branch_a)
      make_dr(sales_branch_b)

      get finance_daily_reconciliations_path

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("select[name='branch_id'] option[selected]")).to be_nil
      expect(doc.at_css("h1.page-title").text).to include(I18n.t("finance.daily_reconciliations.index.filter_all_sales_branches"))
    end

    it "prefers an explicit branch_id param over the shift-assignment default on the very first visit" do
      make_dr(sales_branch_a)
      make_dr(sales_branch_b)
      create(:shift_assignment, business: business, user: actor, branch: sales_branch_b)

      get finance_daily_reconciliations_path(branch_id: sales_branch_a.id)

      doc = Nokogiri::HTML(response.body)
      selected = doc.at_css("select[name='branch_id'] option[selected]")
      expect(selected["value"]).to eq(sales_branch_a.id.to_s)
    end
  end

  describe "branch name in the page header" do
    it "shows the selected branch's name next to the page title" do
      make_dr(sales_branch_a)
      make_dr(sales_branch_b)

      get finance_daily_reconciliations_path(branch_id: sales_branch_a.id)

      expect(Nokogiri::HTML(response.body).at_css("h1.page-title").text).to include(sales_branch_a.name)
    end

    it "shows 'All Branches' when no branch is selected" do
      make_dr(sales_branch_a)
      make_dr(sales_branch_b)

      get finance_daily_reconciliations_path(branch_id: "")

      expect(Nokogiri::HTML(response.body).at_css("h1.page-title").text)
        .to include(I18n.t("finance.daily_reconciliations.index.filter_all_sales_branches"))
    end
  end
end
