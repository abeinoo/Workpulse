require "rails_helper"

# Browser behaviour of the Low Stock "إنشاء طلب شراء" review modal: every
# row's supplier stays editable, changing it MOVES the row to that supplier's
# group (created on demand, never duplicated), "بدون مورد" is a valid choice
# that never blocks confirmation, and the POST groups by the FINAL supplier.
RSpec.describe "Low Stock purchase request review", type: :system do
  let(:business)    { create(:business) }
  let(:owner)       { create(:user, :super_admin, business: business) }
  let!(:supplier_a) { business.suppliers.create!(name: "Supplier A") }
  let!(:supplier_b) { business.suppliers.create!(name: "Supplier B") }
  let!(:wh)         { business.warehouses.create!(name: "Main") }

  def low_product(name, sku, cost, supplier)
    business.products.create!(name: name, sku: sku, initial_cost_price: cost, average_cost_price: cost,
                              low_stock_level: 5, reorder_level: 5, reorder_quantity: 10,
                              default_supplier: supplier)
  end

  let!(:product_1) { low_product("Alpha Dye", "AL-1", 10, supplier_a) }
  let!(:product_2) { low_product("Beta Oil", "BE-1", 20, supplier_a) }
  let!(:product_3) { low_product("Gamma Gel", "GA-1", 30, nil) }

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

  def supplier_select_for(product)
    find(".review-row", text: product.name).find("select[data-field='supplierId']")
  end

  def title_for(supplier, locale: "en")
    if supplier
      I18n.t("inventory.dashboard.review_group_title", supplier: supplier.name, locale: locale)
    else
      I18n.t("inventory.dashboard.review_group_title_no_supplier", locale: locale)
    end
  end

  it "keeps every supplier editable and moves rows between groups without duplicating them" do
    open_review

    # Initial grouping: Supplier A (Alpha, Beta) + no supplier (Gamma).
    expect(all(".review-group").size).to eq(2)
    expect(group_for(title_for(supplier_a))).to have_text("Alpha Dye").and have_text("Beta Oil")
    expect(group_for(title_for(nil))).to have_text("Gamma Gel")
    expect(all("select[data-field='supplierId']").size).to eq(3)
    expect(all("select[data-field='supplierId'][disabled]")).to be_empty

    # A. Supplier A -> Supplier B: a new group appears.
    supplier_select_for(product_1).select("Supplier B")
    expect(group_for(title_for(supplier_b))).to have_text("Alpha Dye")
    expect(group_for(title_for(supplier_a))).not_to have_text("Alpha Dye")

    # C. No supplier -> Supplier B: joins the existing group; the empty
    # no-supplier group disappears.
    supplier_select_for(product_3).select("Supplier B")
    expect(page).to have_no_css(".review-group", text: title_for(nil))
    expect(group_for(title_for(supplier_b))).to have_text("Alpha Dye").and have_text("Gamma Gel")

    # B. Supplier A -> no supplier, still editable after a previous selection.
    supplier_select_for(product_2).select(I18n.t("inventory.dashboard.review_no_supplier"))
    expect(page).to have_no_css(".review-group", text: title_for(supplier_a))
    expect(group_for(title_for(nil))).to have_text("Beta Oil")
    expect(page).to have_text(I18n.t("inventory.dashboard.review_missing_supplier_hint"))

    # Each product appears exactly once, and the unit price was kept.
    expect(all(".review-row").size).to eq(3)
    expect(find(".review-row", text: "Alpha Dye").find("input[data-field='unitPrice']").value).to eq("10.0")
    within(group_for(title_for(supplier_b))) do
      expect(page).to have_css(".review-group-count", text: "2")
    end
    expect(find("[data-low-stock-selection-target='reviewRequestCount']")).to have_text("2")

    # E. Moved several times — only the final supplier counts.
    supplier_select_for(product_1).select("Supplier A")
    supplier_select_for(product_1).select("Supplier B")

    expect(page).to have_button(I18n.t("inventory.dashboard.review_confirm"), disabled: false)
    expect {
      click_button I18n.t("inventory.dashboard.review_confirm")
      expect(page).to have_text(I18n.t("inventory.purchase_requests.just_created_title"))
    }.to change(PurchaseRequest, :count).by(2).and change(PurchaseRequestItem, :count).by(3)

    expect(PurchaseRequest.find_by!(supplier: supplier_b).items.map(&:product)).to contain_exactly(product_1, product_3)
    expect(PurchaseRequest.find_by!(supplier_id: nil).items.map(&:product)).to contain_exactly(product_2)
    expect(PurchaseRequest.where(supplier: supplier_a)).to be_empty
  end

  it "AR: groups as \"طلب شراء — المورد\" / \"بدون مورد\" and creates a no-supplier request" do
    open_review(locale: "ar")

    expect(page).to have_css(".review-group", text: title_for(supplier_a, locale: "ar"))
    expect(page).to have_css(".review-group", text: "طلب شراء — بدون مورد")
    expect(page).to have_text("عدد الأصناف")
    expect(supplier_select_for(product_3).value).to eq("")
    expect(supplier_select_for(product_3)).to have_css("option", text: "بدون مورد")

    expect {
      click_button I18n.t("inventory.dashboard.review_confirm", locale: "ar")
      expect(page).to have_text(I18n.t("inventory.purchase_requests.just_created_title", locale: "ar"))
    }.to change(PurchaseRequest, :count).by(2)

    expect(page).to have_text("بدون مورد")
    expect(PurchaseRequest.find_by!(supplier_id: nil).items.map(&:product)).to contain_exactly(product_3)
  end

  context "when no product has a supplier" do
    before do
      Product.where(id: [ product_1.id, product_2.id ]).update_all(default_supplier_id: nil)
      # No reorder quantity configured — must not leave an invalid 0 line.
      product_3.update!(reorder_quantity: 0)
    end

    it "AR: shows ONE no-supplier group, keeps Confirm enabled, and creates one request" do
      open_review(locale: "ar")

      expect(all(".review-group").size).to eq(1)
      expect(page).to have_css(".review-group", text: "طلب شراء — بدون مورد")
      expect(find("[data-low-stock-selection-target='reviewRequestCount']")).to have_text("1")
      expect(find("[data-low-stock-selection-target='reviewItemCount']")).to have_text("3")
      expect(find(".review-row", text: "Gamma Gel").find("input[data-field='quantity']").value.to_d).to eq(1)
      expect(page).to have_no_css("[data-low-stock-selection-target='reviewInvalid']", visible: true)

      confirm = I18n.t("inventory.dashboard.review_confirm", locale: "ar")
      expect(page).to have_button(confirm, disabled: false)
      expect {
        click_button confirm
        expect(page).to have_text(I18n.t("inventory.purchase_requests.just_created_title", locale: "ar"))
      }.to change(PurchaseRequest, :count).by(1).and change(PurchaseRequestItem, :count).by(3)

      request = PurchaseRequest.last
      expect(request.supplier_id).to be_nil
      expect(request).to be_draft
      expect(request.items.map(&:product)).to contain_exactly(product_1, product_2, product_3)
      expect(Supplier.where(name: "بدون مورد")).to be_empty
    end
  end

  it "creates three requests for Supplier A, Supplier B and no supplier" do
    product_4 = low_product("Delta Wax", "DE-1", 40, nil)
    r = business.goods_receipts.build(warehouse: wh, received_on: Date.current)
    r.items.build(product: product_4, quantity: 1, unit_cost: 40)
    Inventory::GoodsReceiptPoster.new(r).call

    open_review
    supplier_select_for(product_2).select("Supplier B")
    expect(group_for(title_for(supplier_b))).to have_text("Beta Oil")

    expect {
      click_button I18n.t("inventory.dashboard.review_confirm")
      expect(page).to have_text(I18n.t("inventory.purchase_requests.just_created_title"))
    }.to change(PurchaseRequest, :count).by(3)

    expect(PurchaseRequest.find_by!(supplier: supplier_a).items.map(&:product)).to contain_exactly(product_1)
    expect(PurchaseRequest.find_by!(supplier: supplier_b).items.map(&:product)).to contain_exactly(product_2)
    expect(PurchaseRequest.find_by!(supplier_id: nil).items.map(&:product)).to contain_exactly(product_3, product_4)
  end

  it "disables Confirm only for an invalid quantity/price, and says why" do
    open_review

    find(".review-row", text: "Gamma Gel").find("input[data-field='unitPrice']").fill_in(with: "0")
    expect(page).to have_text(I18n.t("inventory.dashboard.review_invalid_lines"))
    expect(page).to have_button(I18n.t("inventory.dashboard.review_confirm"), disabled: true)
    expect(page).to have_css(".review-row input[data-field='unitPrice'][aria-invalid='true']")

    find(".review-row", text: "Gamma Gel").find("input[data-field='unitPrice']").fill_in(with: "30")
    expect(page).to have_no_text(I18n.t("inventory.dashboard.review_invalid_lines"))
    expect(page).to have_button(I18n.t("inventory.dashboard.review_confirm"), disabled: false)
  end
end
