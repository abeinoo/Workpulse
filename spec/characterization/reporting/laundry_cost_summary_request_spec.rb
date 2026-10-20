require "rails_helper"
require "csv"

# Characterization (Pilot 11 — Reporting: laundry labour-cost report, M1) —
# CURRENT web contract of GET /laundry/reports/cost_summary(.csv)
# (Laundry::Reports::CostSummaryController#index) that the M4 relocation must
# keep (next-pilot-selection.md §26.6, gaps G1, G2, G4, G5). Pinned against the
# unchanged code at 96cfc31.
#
# Already pinned elsewhere, not repeated: payroll / stock-issue visibility, the
# restricted and blocked states and their CSV rows
# (spec/requests/laundry/cost_summary_visibility_spec.rb), the access gate
# (spec/requests/laundry/cost_reports_authorization_spec.rb).
RSpec.describe "Laundry cost summary — web contract (characterization)", type: :request do
  let(:business)        { create(:business, timezone: "UTC", business_day_start_hour: 6) }
  let!(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let!(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:owner)           { create(:user, :owner, business: business) }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms, permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def html = Nokogiri::HTML(response.body)
  def t_cost(key) = I18n.t("laundry.reports.cost_summary.#{key}")
  def csv_rows = CSV.parse(response.body.delete_prefix(Finance::Reports::CsvExporter::BOM))

  describe "G2 — default date range is the BusinessDay month" do
    it "uses the business day, not the calendar day, before the start hour on the 1st" do
      # 03:00 UTC on 1 November is still the 31 October business day (start hour 6).
      travel_to Time.utc(2026, 11, 1, 3, 0) do
        sign_in owner
        get laundry_reports_cost_summary_path
        expect(html.at_css('input[name="from"]')["value"]).to eq("2026-10-01")
        expect(html.at_css('input[name="to"]')["value"]).to eq("2026-10-31")

        get laundry_reports_cost_summary_path(format: :csv)
        expect(csv_rows.drop(1).map(&:last).uniq).to eq([ "2026-10-01 - 2026-10-31" ])
      end
    end

    it "uses the current month once the business day has started" do
      travel_to Time.utc(2026, 11, 1, 7, 0) do
        sign_in owner
        get laundry_reports_cost_summary_path
        expect(html.at_css('input[name="from"]')["value"]).to eq("2026-11-01")
        expect(html.at_css('input[name="to"]')["value"]).to eq("2026-11-30")

        get laundry_reports_cost_summary_path(format: :csv)
        expect(csv_rows.drop(1).map(&:last).uniq).to eq([ "2026-11-01 - 2026-11-30" ])
      end
    end

    it "falls back to the default for an unparseable date parameter" do
      travel_to Time.utc(2026, 11, 15, 12, 0) do
        sign_in owner
        get laundry_reports_cost_summary_path(from: "not-a-date", to: "2026-11-20")
        expect(html.at_css('input[name="from"]')["value"]).to eq("2026-11-01")
        expect(html.at_css('input[name="to"]')["value"]).to eq("2026-11-20")
      end
    end
  end

  describe "G4 — HTML card set and order" do
    def card_labels   = html.css(".stat-card .stat-card__label").map { |n| n.text.strip }
    def section_titles = html.css(".card .card-header .card-title").map { |n| n.text.strip }

    # view_payroll whose scope covers the laundry branch (decision of 2026-10-19).
    it "shows the full card set, in order, to a viewer with view_payroll" do
      sign_in user_with("view_laundry_cost_reports", "view_payroll", scopes: { "view_payroll" => "business" })
      get laundry_reports_cost_summary_path

      expect(card_labels).to eq(%w[towels_consumed standard_branch_cost payroll_cost direct_expenses material_cost
                                   total_actual_cost coverage_variance actual_cost_per_towel]
                                  .map { |key| t_cost("cards.#{key}") })
      expect(section_titles).to eq([ t_cost("cards.coverage_variance"), t_cost("material_details.title"),
                                     t_cost("payroll_periods_included") ])
    end

    it "shows the owner the same full card set" do
      sign_in owner
      get laundry_reports_cost_summary_path

      expect(card_labels.size).to eq(8)
      expect(section_titles.size).to eq(3)
    end

    it "shows only the payroll-independent cards, in order, without view_payroll" do
      sign_in user_with("view_laundry_cost_reports")
      get laundry_reports_cost_summary_path

      expect(card_labels).to eq(%w[towels_consumed standard_branch_cost direct_expenses material_cost]
                                  .map { |key| t_cost("cards.#{key}") })
      expect(section_titles).to eq([ t_cost("material_details.title") ])
    end
  end

  describe "G5 — CSV response" do
    it "is a text/csv attachment named after the calendar date, starting with a UTF-8 BOM" do
      travel_to Time.utc(2026, 11, 1, 3, 0) do # calendar 1 November, business day 31 October
        sign_in owner
        get laundry_reports_cost_summary_path(format: :csv)

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/csv")
        expect(response.headers["Content-Disposition"]).to start_with("attachment")
        expect(response.headers["Content-Disposition"]).to include('filename="laundry_cost_summary_2026-11-01.csv"')
        expect(response.body.b).to start_with("\xEF\xBB\xBF".b)
        expect(csv_rows.first).to eq([ t_cost("csv.category"), t_cost("csv.amount"), t_cost("csv.period") ])
      end
    end
  end

  describe "G1 — the CSV standard-cost row counts only the selected branch" do
    let(:actor)      { create(:user, business: business) }
    let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

    def receive_towels!(destination:, confirmed:)
      Laundry::TowelAdjuster.new(actor: actor).call(towel_type: towel_type, branch: sales_branch, status: "clean",
                                                     adjustment_quantity: confirmed + 10, reason: "test setup")
      transfer = Laundry::TowelTransferCreator.create(actor: actor, params: {
        source_branch_id: sales_branch.id, destination_branch_id: destination.id, towel_status: "dirty",
        items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: confirmed } ]
      }).transfer
      Laundry::TowelTransferCreator.new(transfer).dispatch(actor: actor)
      Laundry::TowelTransferCreator.new(transfer.reload)
                                   .receive(actor: actor, confirmed_quantities: { transfer.items.first.id => confirmed })
    end

    it "excludes receipts at a laundry branch that was later deactivated" do
      business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.5, effective_from: 1.year.ago)
      old_laundry = create(:branch, business: business, branch_type: "laundry")
      receive_towels!(destination: old_laundry, confirmed: 40)
      old_laundry.update_column(:active, false)
      receive_towels!(destination: laundry_branch, confirmed: 100)

      sign_in owner
      get laundry_reports_cost_summary_path(format: :csv,
                                            from: Date.current.beginning_of_month.iso8601,
                                            to: Date.current.end_of_month.iso8601)

      amounts = csv_rows.drop(1).to_h { |row| [ row[0], row[1] ] }
      expect(BigDecimal(amounts[t_cost("standard_branch_cost")])).to eq(150)
    end
  end
end
