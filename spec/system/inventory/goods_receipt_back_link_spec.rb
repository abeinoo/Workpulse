require "rails_helper"

# Browser regression: the new Goods Receipt form's Back link returns to the
# Purchase Request it was opened from (Arabic and English), and to the Goods
# Receipts list when opened from there.
RSpec.describe "New Goods Receipt — Back navigation (browser)", type: :system do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:product)  { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 10) }

  let!(:pr) do
    request = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: admin)
    request.items.build(product: product, quantity: 10, unit_price: 20, source_warehouse: warehouse)
    request.save!
    request.update_columns(status: "pending_approval", submitted_by_id: admin.id)
    Inventory::PurchaseRequestApproval.new(purchase_request_id: request.id, actor: admin).approve!
    request.reload
  end

  %w[en ar].each do |locale|
    it "from a Purchase Request (#{locale}): Back returns to that request" do
      admin.update!(preferred_locale: locale)
      sign_in admin
      visit inventory_purchase_request_path(pr)

      click_link I18n.t("inventory.purchase_requests.actions.create_goods_receipt", locale: locale)
      expect(page).to have_current_path(new_inventory_goods_receipt_path(purchase_request_id: pr.id))

      find("[data-testid='goods-receipt-back-link']", text: I18n.t("forms.back", locale: locale)).click
      expect(page).to have_current_path(inventory_purchase_request_path(pr))
    end
  end

  it "from the Goods Receipts list: Back returns to the list" do
    sign_in admin
    visit inventory_goods_receipts_path

    click_link I18n.t("inventory.goods_receipts.new_action"), match: :first
    expect(page).to have_current_path(new_inventory_goods_receipt_path)

    find("[data-testid='goods-receipt-back-link']").click
    expect(page).to have_current_path(inventory_goods_receipts_path)
  end
end
