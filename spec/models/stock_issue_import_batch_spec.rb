require "rails_helper"

RSpec.describe StockIssueImportBatch, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Main Branch", active: true) }
  let(:stock_issue) do
    business.stock_issues.create!(warehouse: warehouse, branch: branch, issued_on: Date.current, status: :draft)
  end

  describe "associations" do
    it { is_expected.to belong_to(:business) }
    it { is_expected.to belong_to(:warehouse) }
    it { is_expected.to belong_to(:branch) }
    it { is_expected.to belong_to(:stock_issue) }
    it { is_expected.to have_many(:rows) }
  end

  it "defaults to draft status" do
    batch = StockIssueImportBatch.create!(business: business, warehouse: warehouse, branch: branch, stock_issue: stock_issue)
    expect(batch).to be_draft
  end
end
