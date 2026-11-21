require "rails_helper"

# Browser behaviour of the Low Stock "إنشاء طلب شراء" review modal: rows are
# grouped by destination WAREHOUSE (one request per warehouse, several
# suppliers per request). Every alert comes from one warehouse's own setting,
# so every row already has its warehouse (no picker) and suggests that
# warehouse's own reorder quantity. Every row's supplier stays editable and is
# the line's own; "بدون مورد" is a valid choice that never blocks confirmation.
RSpec.describe "Low Stock purchase request review", type: :system do
  let(:business)    { create(:business) }
  let(:owner)       { create(:user, :super_admin, business: business) }
  let!(:supplier_a) { business.suppliers.create!(name: "Supplier A") }
  let!(:supplier_b) { business.suppliers.create!(name: "Supplier B") }
  let!(:wh)         { business.warehouses.create!(name: "Main") }
  let!(:wh_2)       { business.warehouses.create!(name: "Second") }
  let!(:responsible) { purchaser_with_custody(business, first_name: "Rami") }

  # Low (threshold 5) in `warehouse`, with that warehouse's own reorder quantity.
  def low_product(name, sku, cost, supplier, warehouse:, reorder: 10)
    business.products.create!(name: name, sku: sku, initial_cost_price: cost, average_cost_price: cost, default_supplier: supplier)
            .tap { |p| p.product_warehouse_settings.create!(warehouse: warehouse, low_stock_level: 5, reorder_quantity: reorder) }
  end

  let!(:product_1) { low_product("Alpha Dye", "AL-1", 10, supplier_a, warehouse: wh) }
  let!(:product_2) { low_product("Beta Oil", "BE-1", 20, supplier_a, warehouse: wh) }
  let!(:product_3) { low_product("Gamma Gel", "GA-1", 30, nil, warehouse: wh_2, reorder: 7) }

  before do
    [ product_1, product_2, product_3 ].each do |product|
      r = business.goods_receipts.build(warehouse: wh, received_on: Date.current)
      r.items.build(product: product, quantity: 1, unit_cost: product.average_cost_price)
      Inventory::GoodsReceiptPoster.new(r).call
    end
  end

  def open_review(locale: "en")
    owner.update!(preferred_locale: locale)
    sign_in owner
    visit inventory_low_stock_report_path
    find(".low-stock-check-all").check
    click_button I18n.t("inventory.dashboard.create_purchase_request", locale: locale)
    expect(page).to have_css(".review-group")
  end

  def group_for(title) = find(".review-group", text: title)
  def row_for(product) = find(".review-row", text: product.name)
  def supplier_select_for(product) = row_for(product).find("select[data-field='supplierId']")

  def title_for(warehouse, locale: "en")
    if warehouse
      I18n.t("inventory.dashboard.review_group_title", warehouse: warehouse.name, locale: locale)
    else
      I18n.t("inventory.dashboard.review_group_title_no_warehouse", locale: locale)
    end
  end

  def confirm_button(locale: "en") = I18n.t("inventory.dashboard.review_confirm", locale: locale)

  it "groups every row under its own warehouse, with no warehouse picker, and keeps line suppliers" do
    open_review

    expect(all("select[data-field='warehouseId']")).to be_empty
    expect(page).to have_no_text(I18n.t("inventory.dashboard.review_missing_warehouse"))
    expect(group_for(title_for(wh))).to have_text("Alpha Dye").and have_text("Beta Oil")
    expect(group_for(title_for(wh_2))).to have_text("Gamma Gel")
    expect(find("[data-low-stock-selection-target='reviewRequestCount']")).to have_text("2")
    # Each row suggests its own warehouse's reorder quantity.
    expect(row_for(product_3).find("input[data-field='quantity']").value.to_d).to eq(7)
    expect(row_for(product_1).find("input[data-field='quantity']").value.to_d).to eq(10)

    # Default suppliers are suggested per line; all stay editable.
    expect(supplier_select_for(product_1).value).to eq(supplier_a.id.to_s)
    expect(supplier_select_for(product_3).value).to eq("")
    expect(all("select[data-field='supplierId'][disabled]")).to be_empty

    # Changing a supplier keeps the row in its warehouse group (no regrouping).
    supplier_select_for(product_2).select("Supplier B")
    expect(group_for(title_for(wh))).to have_text("Beta Oil")
    expect(row_for(product_1).find("input[data-field='unitPrice']").value).to eq("10.0")

    expect {
      find("#low-stock-responsible-employee").select(responsible.full_name)
      click_button confirm_button
      expect(page).to have_text(I18n.t("inventory.purchase_requests.just_created_title"))
    }.to change(PurchaseRequest, :count).by(2).and change(PurchaseRequestItem, :count).by(3)

    main = PurchaseRequest.find_by!(warehouse: wh)
    expect(main.items.map { |i| [ i.product, i.supplier ] })
      .to contain_exactly([ product_1, supplier_a ], [ product_2, supplier_b ])
    expect(PurchaseRequest.find_by!(warehouse: wh_2).items.map { |i| [ i.product, i.supplier, i.quantity ] })
      .to contain_exactly([ product_3, nil, 7 ])
    expect(PurchaseRequest.pluck(:supplier_id).uniq).to eq([ nil ])
    expect(PurchaseRequest.pluck(:responsible_employee_id).uniq).to eq([ responsible.id ]) # one for the batch
    expect(product_2.reload.default_supplier).to eq(supplier_a) # override never touches the product
  end

  it "the same product low in two warehouses gives one row per warehouse, each with its own quantity" do
    product_1.product_warehouse_settings.create!(warehouse: wh_2, low_stock_level: 3, reorder_quantity: 2)
    open_review

    expect(group_for(title_for(wh))).to have_text("Alpha Dye")
    expect(group_for(title_for(wh_2))).to have_text("Alpha Dye")
    quantities = all(".review-row", text: "Alpha Dye").map { |row| row.find("input[data-field='quantity']").value.to_d }
    expect(quantities).to contain_exactly(10, 2)
  end

  it "AR: groups as \"طلب شراء — المستودع\", keeps \"بدون مورد\" valid and creates the request" do
    open_review(locale: "ar")

    expect(page).to have_css(".review-group", text: title_for(wh, locale: "ar"))
    expect(page).to have_css(".review-group", text: title_for(wh_2, locale: "ar"))
    expect(page).to have_text("عدد الأصناف")
    expect(supplier_select_for(product_3).value).to eq("")
    expect(supplier_select_for(product_3)).to have_css("option", text: "بدون مورد")

    expect {
      find("#low-stock-responsible-employee").select(responsible.full_name)
      click_button confirm_button(locale: "ar")
      expect(page).to have_text(I18n.t("inventory.purchase_requests.just_created_title", locale: "ar"))
    }.to change(PurchaseRequest, :count).by(2)

    # Alpha and Beta default to Supplier A, Gamma has none: one named supplier.
    expect(page).to have_text("Supplier A")
    expect(PurchaseRequest.last.items.find_by!(product: product_3).supplier_id).to be_nil
    expect(Supplier.where(name: "بدون مورد")).to be_empty
  end

  context "when no product has a supplier" do
    before do
      Product.where(id: [ product_1.id, product_2.id ]).update_all(default_supplier_id: nil)
      # No reorder quantity configured there — must not leave an invalid 0 line.
      product_3.product_warehouse_settings.sole.update!(reorder_quantity: 0)
    end

    it "keeps Confirm enabled and creates one request per warehouse without suppliers" do
      open_review(locale: "ar")

      expect(find("[data-low-stock-selection-target='reviewItemCount']")).to have_text("3")
      expect(row_for(product_3).find("input[data-field='quantity']").value.to_d).to eq(1)
      expect(page).to have_no_css("[data-low-stock-selection-target='reviewInvalid']", visible: true)

      expect(page).to have_button(confirm_button(locale: "ar"), disabled: false)
      expect {
        find("#low-stock-responsible-employee").select(responsible.full_name)
        click_button confirm_button(locale: "ar")
        expect(page).to have_text(I18n.t("inventory.purchase_requests.just_created_title", locale: "ar"))
      }.to change(PurchaseRequest, :count).by(2).and change(PurchaseRequestItem, :count).by(3)

      expect(PurchaseRequest.all).to all(be_draft)
      expect(PurchaseRequestItem.pluck(:supplier_id)).to all(be_nil)
    end
  end

  it "disables Confirm for an invalid quantity/price too, and says why" do
    open_review

    row_for(product_3).find("input[data-field='unitPrice']").fill_in(with: "0")
    expect(page).to have_text(I18n.t("inventory.dashboard.review_invalid_lines"))
    expect(page).to have_button(confirm_button, disabled: true)
    expect(page).to have_css(".review-row input[data-field='unitPrice'][aria-invalid='true']")

    row_for(product_3).find("input[data-field='unitPrice']").fill_in(with: "30")
    expect(page).to have_no_text(I18n.t("inventory.dashboard.review_invalid_lines"))
    expect(page).to have_button(confirm_button, disabled: false)
  end
end
