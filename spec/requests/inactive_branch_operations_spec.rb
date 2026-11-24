require "rails_helper"

# BUG-029 — crafted requests naming an inactive branch (the pickers list active
# branches only) are refused by every laundry entry point, write nothing, and
# history at the inactive branch stays readable. Stock Issues no longer take a
# branch (warehouse-based authorization, Nov 24 2026): a submitted branch is
# ignored and the WAREHOUSE's status decides.
RSpec.describe "New operations at an inactive branch (BUG-029)", type: :request do
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let(:sales)      { create(:branch, business: business, branch_type: "sales", name: "Sales") }
  let(:laundry)    { create(:branch, business: business, branch_type: "laundry", name: "Laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:warehouse)  { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  def deactivate(branch) = branch.update_column(:active, false)

  before { sign_in owner }

  describe "laundry" do
    it "refuses a towel transfer to an inactive branch" do
      deactivate(laundry)

      expect {
        post laundry_towel_transfers_path, params: { towel_transfer: {
          source_branch_id: sales.id, destination_branch_id: laundry.id,
          items_attributes: { "0" => { towel_type_id: towel_type.id, declared_quantity: 5 } }
        } }
      }.not_to change(TowelTransfer, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a towel adjustment at an inactive branch" do
      deactivate(sales)

      expect {
        post laundry_towel_adjustments_path, params: { towel_adjustment: {
          branch_id: sales.id, towel_type_id: towel_type.id, adjustment_type: "correction",
          status: "clean", adjustment_quantity: 5, reason: "count"
        } }
      }.not_to change { [ TowelAdjustment.count, TowelLedgerEntry.count ] }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a laundry batch at an inactive laundry" do
      deactivate(laundry)

      expect {
        post laundry_laundry_batches_path, params: { laundry_batch: { laundry_branch_id: laundry.id, towel_type_id: towel_type.id } }
      }.not_to change(LaundryBatch, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "keeps a transfer at an inactive branch readable" do
      transfer = Laundry::TowelTransferCreator.create(actor: owner, params: {
        source_branch_id: sales.id, destination_branch_id: laundry.id, towel_status: "dirty",
        items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: 5 } ]
      }).transfer
      deactivate(laundry)

      get laundry_towel_transfer_path(transfer)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(laundry.name)
    end
  end

  describe "stock issues (warehouse-based: the branch is not an input)" do
    it "ignores a submitted inactive branch — the issue is made for the selected warehouse" do
      deactivate(sales)

      expect {
        post inventory_stock_issues_path, params: { stock_issue: {
          warehouse_id: warehouse.id, branch_id: sales.id, issued_on: Date.current.to_s,
          items_attributes: { "0" => { product_id: product.id, quantity: 1 } }
        } }
      }.to change(StockIssue, :count).by(1)
      expect(StockIssue.last).to have_attributes(warehouse_id: warehouse.id, branch_id: nil)
    end

    it "refuses a manual stock issue from an inactive warehouse" do
      warehouse.update_column(:status, "inactive")

      expect {
        post inventory_stock_issues_path, params: { stock_issue: {
          warehouse_id: warehouse.id, issued_on: Date.current.to_s,
          items_attributes: { "0" => { product_id: product.id, quantity: 1 } }
        } }
      }.not_to change(StockIssue, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    describe "CSV import from an inactive warehouse" do
      def upload(path)
        file = Rack::Test::UploadedFile.new(StringIO.new("SKU,Quantity\n#{product.sku},1\n"), "text/csv",
                                            original_filename: "issue.csv")
        post path, params: { file: file, warehouse_id: warehouse.id }
      end

      before { warehouse.update_column(:status, "inactive") }

      it "refuses the preview" do
        upload(preview_import_inventory_stock_issues_path)

        expect(response).to redirect_to(import_inventory_stock_issues_path)
        # "not allowed", or "none accessible" when it was the business's only warehouse
        expect(flash[:alert]).to be_in([ I18n.t("inventory.issue_warehouse.errors.not_allowed"),
                                         I18n.t("inventory.issue_warehouse.errors.none_accessible") ])
      end

      it "refuses the import, writing nothing" do
        expect { upload(run_import_inventory_stock_issues_path) }
          .not_to change { [ StockIssue.count, StockIssueImportBatch.count ] }
        expect(response).to redirect_to(import_inventory_stock_issues_path)
      end
    end
  end
end
