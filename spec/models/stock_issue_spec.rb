require "rails_helper"

RSpec.describe StockIssue, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  def build_issue(status: "draft")
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    i.items.build(product: product, quantity: 1) unless status == "draft"
    i.status = status
    i
  end

  describe "defaults" do
    it "defaults a new record to draft" do
      expect(StockIssue.new.status).to eq("draft")
    end
  end

  describe "#destroyable_as_draft?" do
    it "is true only while draft" do
      expect(build_issue(status: "draft").destroyable_as_draft?).to be true
      expect(build_issue(status: "issued").destroyable_as_draft?).to be false
    end
  end

  describe "ImmutableDocument" do
    it "allows destroying a draft" do
      issue = build_issue(status: "draft")
      issue.save!
      expect { issue.destroy }.not_to raise_error
      expect(StockIssue.exists?(issue.id)).to be false
    end

    it "refuses to destroy an issued document" do
      issue = save_stock_issue_in_status!(build_issue(status: "issued"), "issued")
      expect { issue.destroy }.to raise_error(ImmutableDocument::DeletionNotAllowedError)
      expect(StockIssue.exists?(issue.id)).to be true
    end
  end

  describe "item presence" do
    it "allows a draft to have zero items" do
      issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, status: "draft")
      expect(issue).to be_valid
    end

    it "requires at least one item once not draft" do
      issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current,
                                          status: "pending_approval")
      expect(issue).not_to be_valid
      expect(issue.errors[:base]).to be_present
    end
  end

  describe "#excluding_incomplete_imports" do
    it "excludes a draft still tied to an in-progress import batch" do
      real_draft = business.stock_issues.create!(warehouse: warehouse, branch: branch, issued_on: Date.current, status: :draft)
      import_draft = business.stock_issues.create!(warehouse: warehouse, branch: branch, issued_on: Date.current, status: :draft)
      StockIssueImportBatch.create!(business: business, warehouse: warehouse, branch: branch,
                                    stock_issue: import_draft, status: :draft)

      result = StockIssue.for_business(business).excluding_incomplete_imports
      expect(result).to include(real_draft)
      expect(result).not_to include(import_draft)
    end

    it "includes an issue whose import batch has already completed" do
      issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
      issue.items.build(product: product, quantity: 1)
      save_stock_issue_in_status!(issue, :issued)
      StockIssueImportBatch.create!(business: business, warehouse: warehouse, branch: branch,
                                    stock_issue: issue, status: :completed)

      expect(StockIssue.for_business(business).excluding_incomplete_imports).to include(issue)
    end
  end
end
