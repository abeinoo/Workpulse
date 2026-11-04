require "rails_helper"

# The approved attribution rule for an assignment change during a payroll
# period: the last assignment of the period decides the WHOLE period's salary
# and employer insurance — no daily proration or splitting.
#
#   employee        October 2026                      → cost attribution
#   a_to_floating   Branch A to Oct 14, then floating   → Unallocated
#   floating_to_a   floating to Oct 14, then Branch A   → Branch A
#   a_to_b          Branch A to Oct 14, then Branch B   → Branch B
#   none_to_floating no assignment, floating from Oct 15 → Unallocated
#
# Review follows every assignment held during the period (any branch slot plus
# the central slot for anyone floating at some point), cost the last one only.
RSpec.describe "Payroll attribution across a mid-period assignment change" do
  let(:business) { create(:business) }
  let!(:branch_a) { create(:branch, business: business, name: "Branch A") } # lowest id: the fallback branch
  let!(:branch_b) { create(:branch, business: business, name: "Branch B") }
  let(:shift)  { create(:shift, :hour_based, business: business) }
  let(:period) { create(:payroll_period, business: business, period_year: 2026, period_month: 10) }
  let(:owner)  { create(:user, business: business).tap { |u| business.update!(owner: u) } }

  def employee(name) = create(:user, business: business, first_name: name, last_name: "Test")
  def regular(user, branch, from:, to: nil) = create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: from, effective_to: to)
  def floating(user, from:, to: nil) = create(:shift_assignment, :floating, user: user, shift: shift, effective_from: from, effective_to: to)

  let(:jan1)  { Date.new(2026, 1, 1) }
  let(:oct14) { Date.new(2026, 10, 14) }
  let(:oct15) { Date.new(2026, 10, 15) }

  let!(:a_to_floating)    { employee("AtoFloating").tap { |u| regular(u, branch_a, from: jan1, to: oct14); floating(u, from: oct15) } }
  let!(:floating_to_a)    { employee("FloatingToA").tap { |u| floating(u, from: jan1, to: oct14); regular(u, branch_a, from: oct15) } }
  let!(:a_to_b)           { employee("AtoB").tap { |u| regular(u, branch_a, from: jan1, to: oct14); regular(u, branch_b, from: oct15) } }
  let!(:none_to_floating) { employee("NoneToFloating").tap { |u| floating(u, from: oct15) } }

  before do
    { a_to_floating => 10, floating_to_a => 20, a_to_b => 30, none_to_floating => 40 }.each do |user, employer|
      create(:payroll_entry, payroll_period: period, user: user, insured: true, employer_insurance_amount: employer,
                             base_salary: employer * 10, total_overtime: 0, total_bonuses: 0, net_salary: employer * 10)
    end
    branch_a.update!(branch_manager: create(:user, business: business))
    branch_b.update!(branch_manager: create(:user, business: business))
  end

  it "attributes each employee's whole employer insurance by the last assignment" do
    cost = Payroll::EmployerInsuranceCost.for(period)

    expect(cost.by_branch).to eq(branch_a.id => 20, branch_b.id => 30)
    expect(cost.unallocated).to eq(50) # a_to_floating 10 + none_to_floating 40
    expect(cost.by_branch.values.sum + cost.unallocated).to eq(cost.total)
  end

  it "attributes each employee's whole gross salary by the last assignment, never through the fallback branch" do
    sources = Finance::Reports::ExpenseSources.new(business, year: 2026, month: 10)

    expect(sources.payroll_costs).to eq(branch_a.id => 200, branch_b.id => 300)
    expect(sources.unallocated_payroll_cost).to eq(500) # 100 + 400
    expect(sources.payroll_costs.values.sum + sources.unallocated_payroll_cost).to eq(1_000) # every salary once
    expect(sources.payroll_entries_by_branch.transform_values { |entries| entries.map(&:user) })
      .to eq(branch_a.id => [ floating_to_a ], branch_b.id => [ a_to_b ])
    expect(sources.unallocated_payroll_entries.map(&:user)).to contain_exactly(a_to_floating, none_to_floating)
  end

  it "shows the same split in Branch Profitability, with business-wide totals counting each salary once" do
    table = Finance::Reports::BranchProfitability.new(business, year: 2026, month: 10).call

    expect(table.rows.to_h { |r| [ r[:branch], r[:payroll] ] }).to eq("Branch A" => 200, "Branch B" => 300)
    expect(table.unallocated[:payroll]).to eq(500)
    expect(table.totals[:payroll]).to eq(1_000)
  end

  it "opens a review slot for every branch held during the period and the central slot for anyone floating in it" do
    Payroll::SubmitForReview.call(period: period, by: owner)

    expect(period.payroll_period_branch_reviews.pluck(:branch_id)).to contain_exactly(branch_a.id, branch_b.id, nil)
    expect(Payroll::CentralReview.new(period).floating_user_ids)
      .to contain_exactly(a_to_floating.id, floating_to_a.id, none_to_floating.id)
  end

  describe "payroll pages", type: :request do
    before { sign_in owner }

    def branch_cell_of(user)
      Nokogiri::HTML(response.body).css("tr").find { |tr| tr.text.include?(user.full_name) }
              &.at_css("td[data-label='#{I18n.t('payroll.show.branch_col')}']")&.text&.strip
    end

    it "labels an employee whose last assignment is floating as Floating on the period page, never an earlier branch" do
      get payroll_period_path(period)

      expect(response).to have_http_status(:ok)
      expect(branch_cell_of(a_to_floating)).to eq(I18n.t("payroll_dashboard.floating_employee"))
      expect(branch_cell_of(none_to_floating)).to eq(I18n.t("payroll_dashboard.floating_employee"))
      expect(branch_cell_of(floating_to_a)).to eq("Branch A")
      expect(branch_cell_of(a_to_b)).to eq("Branch B")
    end

    it "groups floating salaries as Unallocated in the payroll dashboard's branch costs, not as No branch" do
      period.update_columns(status: "finalized")
      unassigned = employee("Unassigned")
      create(:payroll_entry, payroll_period: period, user: unassigned, base_salary: 7, net_salary: 7)

      get payroll_dashboard_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("payroll_dashboard.unallocated"))
      expect(response.body).to include(I18n.t("payroll_dashboard.no_branch")) # a genuinely unassigned employee stays distinct
    end
  end
end
