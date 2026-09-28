require "rails_helper"

RSpec.describe "Inventory::StockIssues costing display", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }

  def product!(sku)
    business.products.create!(name: "Product #{sku}", sku: sku, selling_markup_percentage: 50)
  end

  def receive!(product, qty, unit_cost)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: qty, unit_cost: unit_cost)
    Inventory::GoodsReceiptPoster.new(receipt).call
  end

  def draft_issue!(product, qty)
    issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: owner)
    issue.items.build(product: product, quantity: qty)
    issue.save!
    issue
  end

  def items_table
    Nokogiri::HTML(response.body).at_css("#items").text.squish
  end

  %w[en ar].each do |locale|
    context "in #{locale}" do
      before do
        owner.update!(preferred_locale: locale)
        sign_in owner
      end

      it "shows the average cost (not 0.00, not the selling price) on a draft issue" do
        product = product!("UYN1")
        receive!(product, 10, 31)
        issue = draft_issue!(product, 2)

        get inventory_stock_issue_path(issue)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(dir="#{locale == 'ar' ? 'rtl' : 'ltr'}"))
        text = items_table
        expect(text).to include("31.00")
        expect(text).to include("62.00")
        expect(text).to include(I18n.t("inventory.stock_issues.cost_estimated_hint", locale: locale))
        expect(text).not_to include("46.50") # selling price (31 * 1.5)
      end

      it "shows a Cost unavailable state when the product has no cost data" do
        issue = draft_issue!(product!("NOCOST"), 2)

        get inventory_stock_issue_path(issue)

        text = items_table
        expect(text).to include(I18n.t("inventory.stock_issues.cost_unavailable", locale: locale))
        expect(text).to include(I18n.t("inventory.stock_issues.cost_unavailable_hint", locale: locale))
      end

      it "shows the estimated total on the index row" do
        product = product!("IDX")
        receive!(product, 10, 31)
        draft_issue!(product, 2)

        get inventory_stock_issues_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("62.00")
      end
    end
  end
end
