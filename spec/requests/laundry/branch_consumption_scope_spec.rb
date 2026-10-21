require "rails_helper"
require "csv"

# BUG-001 (TD-P11-1) — the branch consumption report applies the viewer's
# view_laundry_consumption_reports branch scope to the report itself: the
# default page (no branch chosen), an explicit branch, an out-of-scope branch
# (clamped to the viewer's first allowed branch, the existing behaviour) and the
# CSV export all come from the same scoped result. Real received transfers from
# two sales branches, so the other branch has data that could leak.
RSpec.describe "Laundry branch consumption report — branch scope", type: :request do
  let(:business)       { create(:business) }
  let(:branch_a)       { create(:branch, business: business, branch_type: "sales", name: "Alpha Sales") }
  let(:branch_b)       { create(:branch, business: business, branch_type: "sales", name: "Bravo Sales") }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry", name: "Central Laundry") }
  let(:towel_type)     { business.towel_types.create!(name: "Bath Towel") }
  let(:actor)          { create(:user, business: business) }
  let(:owner)          { create(:user, :owner, business: business) }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms,
                                              permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def scoped(scope) = user_with("view_laundry_consumption_reports", scopes: { "view_laundry_consumption_reports" => scope })

  # A received sales → laundry transfer of `confirmed` towels (the only kind the report counts).
  def received_transfer(source, confirmed, laundry: laundry_branch, type: towel_type, by: actor)
    Laundry::TowelAdjuster.new(actor: by).call(towel_type: type, branch: source, status: "clean",
                                               adjustment_quantity: confirmed, reason: "test setup")
    transfer = Laundry::TowelTransferCreator.create(actor: by, params: {
      source_branch_id: source.id, destination_branch_id: laundry.id,
      towel_status: TowelTransfer.infer_towel_status(source, laundry) || "dirty",
      items_attributes: [ { towel_type_id: type.id, declared_quantity: confirmed } ]
    }).transfer
    Laundry::TowelTransferCreator.new(transfer.reload).dispatch(actor: by)
    Laundry::TowelTransferCreator.new(transfer.reload).receive(actor: by, confirmed_quantities: { transfer.items.first.id => confirmed })
  end

  def report = controller.instance_variable_get(:@report)
  def report_branches = report.rows.map { |row| row.branch.name }

  def csv_rows
    get laundry_reports_branch_consumption_path(format: :csv)
    CSV.parse(response.body)
  end

  def csv_branch_names(rows = csv_rows) = rows.map(&:first)

  before do
    business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 2.0, effective_from: 1.year.ago)
    received_transfer(branch_a, 37) # Alpha: 37 towels, 74.00
    received_transfer(branch_b, 58) # Bravo: 58 towels, 116.00
  end

  describe "a branch-scoped viewer (manages Alpha)" do
    let(:viewer) { scoped("branch").tap { |u| branch_a.update!(branch_manager_id: u.id) } }

    before { sign_in viewer }

    it "default page (no branch chosen): only Alpha's rows and totals" do
      get laundry_reports_branch_consumption_path

      expect(response).to have_http_status(:ok)
      expect(report_branches).to eq([ "Alpha Sales" ])
      expect(report).to have_attributes(total_towels: 37, total_cost: 74.0)
      expect(response.body).to include("Alpha Sales")
      expect(response.body).not_to include("Bravo Sales")
    end

    it "CSV with no branch chosen: Alpha's rows only" do
      rows = csv_rows

      expect(response).to have_http_status(:ok)
      expect(csv_branch_names(rows)).to include("Alpha Sales")
      expect(csv_branch_names(rows)).not_to include("Bravo Sales")
      expect(response.body).not_to include("58")
    end

    it "an allowed branch selected: that branch only, in HTML and CSV" do
      get laundry_reports_branch_consumption_path(branch_id: branch_a.id)
      expect(report_branches).to eq([ "Alpha Sales" ])

      get laundry_reports_branch_consumption_path(branch_id: branch_a.id, format: :csv)
      expect(CSV.parse(response.body).map(&:first)).not_to include("Bravo Sales")
    end

    it "an out-of-scope branch requested: clamped to Alpha (existing behaviour) — Bravo never returned, totals scoped" do
      get laundry_reports_branch_consumption_path(branch_id: branch_b.id)

      expect(response).to have_http_status(:ok)
      expect(report_branches).to eq([ "Alpha Sales" ])
      expect(report.total_towels).to eq(37)

      get laundry_reports_branch_consumption_path(branch_id: branch_b.id, format: :csv)
      expect(CSV.parse(response.body).map(&:first)).not_to include("Bravo Sales")
    end
  end

  it "a viewer with no configured scope gets the default (managed branches), not every branch" do
    viewer = user_with("view_laundry_consumption_reports")
    branch_b.update!(branch_manager_id: viewer.id)
    sign_in viewer

    get laundry_reports_branch_consumption_path

    expect(report_branches).to eq([ "Bravo Sales" ])
    expect(report.total_towels).to eq(58)
  end

  describe "a viewer whose scope resolves to no branch" do
    let(:viewer) { scoped("branch") } # manages nothing

    before { sign_in viewer }

    it "sees no branch data on the default page or in the CSV" do
      get laundry_reports_branch_consumption_path
      expect(response).to have_http_status(:ok)
      expect(report.rows).to be_empty
      expect(report).to have_attributes(total_towels: 0, total_cost: 0)
      expect(response.body).not_to include("Alpha Sales")
      expect(response.body).not_to include("Bravo Sales")

      expect(csv_branch_names).not_to include("Alpha Sales", "Bravo Sales")
    end

    it "gets nothing for an explicitly requested branch either" do
      get laundry_reports_branch_consumption_path(branch_id: branch_b.id)

      expect(report.rows).to be_empty
    end
  end

  describe "business-wide viewers" do
    it "a business-scoped viewer still sees both branches (HTML and CSV)" do
      sign_in scoped("business")

      get laundry_reports_branch_consumption_path
      expect(report_branches).to eq([ "Alpha Sales", "Bravo Sales" ])
      expect(report).to have_attributes(total_towels: 95, total_cost: 190.0)

      expect(csv_branch_names).to include("Alpha Sales", "Bravo Sales")
    end

    it "the owner still sees both branches, and can still filter to one" do
      sign_in owner

      get laundry_reports_branch_consumption_path
      expect(report_branches).to eq([ "Alpha Sales", "Bravo Sales" ])

      get laundry_reports_branch_consumption_path(branch_id: branch_b.id)
      expect(report_branches).to eq([ "Bravo Sales" ])
    end

    it "never includes another business's data" do
      other         = create(:business)
      other_sales   = create(:branch, business: other, branch_type: "sales", name: "Foreign Sales")
      other_laundry = create(:branch, business: other, branch_type: "laundry")
      other_type    = other.towel_types.create!(name: "Bath Towel")
      received_transfer(other_sales, 11, laundry: other_laundry, type: other_type, by: create(:user, business: other))
      sign_in owner

      get laundry_reports_branch_consumption_path

      expect(report_branches).not_to include("Foreign Sales")
      expect(report.total_towels).to eq(95)
    end
  end
end
