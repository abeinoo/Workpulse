require "rails_helper"

RSpec.describe StockIssueImportRow, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Main Branch", active: true) }
  let(:stock_issue) do
    business.stock_issues.create!(warehouse: warehouse, branch: branch, issued_on: Date.current, status: :draft)
  end
  let(:batch) do
    StockIssueImportBatch.create!(business: business, warehouse: warehouse, branch: branch, stock_issue: stock_issue)
  end

  describe "associations" do
    it { is_expected.to belong_to(:batch) }
    it { is_expected.to belong_to(:product).optional }
    it { is_expected.to belong_to(:stock_issue_item).optional }
  end

  it "requires a row_number" do
    row = StockIssueImportRow.new(batch: batch)
    expect(row).not_to be_valid
    expect(row.errors[:row_number]).to be_present
  end

  it "allows a nil failure_reason once resolved" do
    row = batch.rows.create!(row_number: 1, status: :resolved, failure_reason: nil)
    expect(row).to be_valid
  end
end
