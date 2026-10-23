require "rails_helper"
require "csv"

# Expenses by Type / by Category: period presets + branch filter. The page's
# header, KPIs, ranking, trend, table and the CSV export all use the same
# validated filters; the branch must belong to the viewer's business.
RSpec.describe "Finance expense reports — period and branch filters", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:north)    { create(:branch, business: business, name: "North") }
  let(:south)    { create(:branch, business: business, name: "South") }
  let(:rent)     { create(:expense_category, business: business, name: "Rent") }
  let(:supplies) { create(:expense_category, business: business, name: "Supplies") }
  let(:cleaning) { create(:expense_type, business: business, expense_category: supplies, name: "Cleaning") }

  let(:other_business) { create(:business) }
  let(:foreign_branch) { create(:branch, business: other_business, name: "Foreign") }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def expense(branch:, category:, amount:, date:, type: nil)
    create(:expense, :approved, business: business, branch: branch, expense_category: category, expense_type: type,
                                amount: amount, expense_date: date)
  end

  def csv_rows(body) = CSV.parse(body.delete_prefix(Finance::Reports::CsvExporter::BOM))

  around { |example| travel_to(Time.utc(2026, 10, 23, 9)) { example.run } }

  before do
    expense(branch: north, category: rent, amount: 1000, date: Date.new(2026, 10, 5))
    expense(branch: south, category: rent, amount: 700, date: Date.new(2026, 10, 6))
    expense(branch: north, category: supplies, type: cleaning, amount: 50, date: Date.new(2026, 9, 10))
    shared = build(:expense, :approved, business: business, branch: nil, expense_category: supplies, expense_type: cleaning,
                                        amount: 300, expense_date: Date.new(2026, 10, 7), distribution_method: "manual")
    shared.expense_allocations.build(branch: north, allocated_amount: 120, allocation_percentage: 40)
    shared.expense_allocations.build(branch: south, allocated_amount: 180, allocation_percentage: 60)
    shared.save!
    create(:expense, :approved, business: other_business, branch: foreign_branch, amount: 55_555, expense_date: Date.new(2026, 10, 5),
                                expense_category: create(:expense_category, business: other_business))
  end

  {
    "by category" => [ :finance_expenses_by_category_report_path, "Supplies" ],
    "by type"     => [ :finance_expenses_by_type_report_path, "Cleaning" ]
  }.each do |name, (path_helper, shared_label)|
    describe name do
      def path(**params) = send(self.class.metadata[:path_helper], **params)

      metadata[:path_helper] = path_helper

      it "keeps the existing default (last 6 months, all branches) with no filters" do
        sign_in owner
        get path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.l(Date.new(2026, 5, 1), format: :long), I18n.l(Date.new(2026, 10, 31), format: :long))
        expect(response.body).to include(%(<option selected="selected" value="last_6_months">))
        expect(response.body).to include(I18n.t("finance.reports.expense_filters.all_branches"))
        expect(response.body).not_to include("alert-warning")

        rows = csv_rows(get(path(format: :csv)) && response.body)
        expect(rows.last).to eq([ I18n.t("finance.reports.total"), "4", "2050.0" ])
      end

      it "applies a preset to the page, its comparison label and the CSV" do
        sign_in owner
        get path(period: "previous_month")

        expect(response.body).to include(I18n.l(Date.new(2026, 9, 1), format: :long), I18n.l(Date.new(2026, 9, 30), format: :long))
        expect(response.body).to include("#{I18n.l(Date.new(2026, 8, 1), format: :long)} – #{I18n.l(Date.new(2026, 8, 31), format: :long)}")

        get path(format: :csv, period: "previous_month")
        expect(csv_rows(response.body)[1..]).to eq([ [ shared_label, "1", "50.0" ], [ I18n.t("finance.reports.total"), "1", "50.0" ] ])
      end

      it "narrows the page and CSV to one branch, a shared expense by its allocated share only" do
        sign_in owner
        get path(period: "current_month", branch_id: north.id)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(<option selected="selected" value="#{north.id}">North</option>))
        expect(response.body).to include(ERB::Util.html_escape(I18n.t("finance.reports.expense_filters.shared_note")))
        # The CSV link and drill-down links carry the same filters.
        csv_href = path(format: :csv, period: "current_month", from: "2026-10-01", to: "2026-10-31", branch_id: north.id)
        expect(response.body).to include(%(href="#{ERB::Util.html_escape(csv_href)}"))
        expect(response.body).to include("branch_id=#{north.id}").and include("from=2026-10-01")

        get path(format: :csv, period: "current_month", branch_id: north.id)
        rows = csv_rows(response.body)
        expect(rows.last).to eq([ I18n.t("finance.reports.total"), "2", "1120.0" ])
        expect(rows.flatten).not_to include("1700.0", "300.0")
      end

      it "lets a non-owner holder of view_expense_reports filter any branch of their business (business-wide permission)" do
        sign_in user_with("view_expense_reports")
        get path(format: :csv, period: "current_month", branch_id: south.id)

        expect(csv_rows(response.body).last).to eq([ I18n.t("finance.reports.total"), "2", "880.0" ])
      end

      it "ignores another business's branch — page and CSV stay on the viewer's own business data" do
        sign_in owner
        get path(period: "current_month", branch_id: foreign_branch.id)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("finance.reports.expense_filters.errors.branch_unavailable"))
        expect(response.body).not_to include("Foreign")

        get path(format: :csv, period: "current_month", branch_id: foreign_branch.id)
        rows = csv_rows(response.body)
        expect(rows.last).to eq([ I18n.t("finance.reports.total"), "3", "2000.0" ])
        expect(rows.flatten).not_to include("55555.0")
      end

      it "falls back to the default period with a warning for a reversed custom range" do
        sign_in owner
        get path(period: "custom", from: "2026-10-31", to: "2026-10-01")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("finance.reports.expense_filters.errors.reversed_range"))
        expect(response.body).to include(I18n.l(Date.new(2026, 5, 1), format: :long))
      end

      it "falls back for an invalid custom date, including in the CSV" do
        sign_in owner
        get path(format: :csv, period: "custom", from: "2026-13-45", to: "2026-10-31")

        expect(response).to have_http_status(:ok)
        expect(csv_rows(response.body).last).to eq([ I18n.t("finance.reports.total"), "4", "2050.0" ])
      end

      it "keeps legacy from/to links (finance dashboard) working as a custom range" do
        sign_in owner
        get path(from: "2026-10-01", to: "2026-10-31")

        expect(response.body).to include(%(<option selected="selected" value="custom">))
        get path(format: :csv, from: "2026-10-01", to: "2026-10-31")
        expect(csv_rows(response.body).last).to eq([ I18n.t("finance.reports.total"), "3", "2000.0" ])
      end

      it "renders an empty period cleanly" do
        sign_in owner
        get path(period: "custom", from: "2020-01-01", to: "2020-01-31")

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("finance.reports.no_data"))
      end

      it "still refuses a user without view_expense_reports, for the page and the CSV" do
        sign_in user_with("view_expenses")
        get path(branch_id: north.id)
        expect(response).to redirect_to(finance_root_path)

        get path(format: :csv, branch_id: north.id)
        expect(response).to redirect_to(finance_root_path)
      end
    end
  end

  it "does not change the other reports that share the header (by branch keeps its plain date filter)" do
    sign_in owner
    get finance_expenses_by_branch_report_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(%(name="period"))
    expect(response.body).not_to include(I18n.t("finance.reports.expense_filters.all_branches"))
  end
end
