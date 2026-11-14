require "rails_helper"

# The Purchase Request page's item editor (before approval): Add Product and
# each row's Edit open one modal — live line total and "request total after
# saving", the supplier pre-fill rule (a deliberately chosen supplier is kept,
# with a note), browser number checks keeping it open — and Delete removes a
# line after confirmation. Arabic RTL.
RSpec.describe "Purchase Request item editor", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:acme)     { business.suppliers.create!(name: "Acme") }
  let!(:beta)     { business.suppliers.create!(name: "Beta") }
  let!(:shampoo)  { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 10, default_supplier: acme) }
  let!(:gel)      { business.products.create!(name: "Gel", sku: "GE-1", average_cost_price: 20, default_supplier: beta) }
  let!(:dye)      { business.products.create!(name: "Dye", sku: "DY-1", average_cost_price: 30) }

  # Shampoo 4 × 10 from Acme = 40.
  let!(:request_record) do
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: owner)
    pr.items.build(product: shampoo, quantity: 4, unit_price: 10, supplier: acme)
    pr.save!
    pr
  end

  def editor = find("[data-purchase-request-item-editor-target='modal']")
  def editor_row = editor.find("tr[data-line-row]")
  def supplier_select = editor_row.find("select[data-supplier-field]")
  def request_total_after = editor.find("[data-testid='item-editor-request-total']").text
  def line_total = editor_row.find("[data-purchase-request-form-target='lineTotal']").text

  def choose_product(text)
    input = editor_row.find("[data-product-combobox-target='input']")
    page.execute_script("arguments[0].blur()", input.native)
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", input.native)
    input.click
    editor_row.find(".pcombo__option", text: text).click
  end

  def visit_request(locale: "en")
    owner.update!(preferred_locale: locale)
    sign_in owner
    visit inventory_purchase_request_path(request_record)
  end

  it "adds a product: supplier from its default, live totals, saved into the table" do
    visit_request
    find("[data-testid='add-item']").click
    expect(editor).to have_text(I18n.t("inventory.purchase_requests.item_editor.add_title"))

    choose_product("Gel")
    expect(supplier_select.value).to eq(beta.id.to_s)
    editor_row.find("[data-quantity-field]").fill_in(with: "3")
    editor_row.find("[data-price-field]").fill_in(with: "20")
    expect(line_total).to include("60.00")
    expect(request_total_after).to include("100.00") # 40 + 60

    editor.find("[data-testid='item-editor-save']").click
    expect(page).to have_text(I18n.t("inventory.purchase_requests.item_added"))
    expect(request_record.reload.items.find_by!(product: gel)).to have_attributes(quantity: 3, unit_price: 20, supplier_id: beta.id)
    expect(page).to have_css("#item-#{request_record.items.find_by!(product: gel).id}", text: "Gel")
  end

  it "edits a row: prefilled, live totals, a deliberately chosen supplier is kept on a product change" do
    line = request_record.items.sole
    visit_request
    find("#item-#{line.id} [data-testid='edit-item']").click

    expect(editor).to have_text(I18n.t("inventory.purchase_requests.item_editor.edit_title"))
    expect(editor_row.find("[data-product-combobox-target='input']").value).to include("Shampoo")
    expect(editor_row.find("[data-quantity-field]").value).to eq("4")
    expect(supplier_select.value).to eq(acme.id.to_s)
    expect(request_total_after).to include("40.00")

    editor_row.find("[data-quantity-field]").fill_in(with: "6")
    expect(line_total).to include("60.00")
    expect(request_total_after).to include("60.00") # the other lines (none) + this one

    supplier_select.select("Beta") # deliberately not Shampoo's default
    choose_product("Dye")
    expect(supplier_select.value).to eq(beta.id.to_s)
    expect(editor_row).to have_css("[data-supplier-kept-note]", visible: true,
                                   text: I18n.t("inventory.purchase_requests.form.supplier_kept_note"))

    editor.find("[data-testid='item-editor-save']").click
    expect(page).to have_text(I18n.t("inventory.purchase_requests.item_updated"))
    expect(line.reload).to have_attributes(product_id: dye.id, quantity: 6, supplier_id: beta.id)
    expect(dye.reload.default_supplier_id).to be_nil # the catalog is untouched
  end

  it "a supplier that was just the old product's default follows the new product" do
    line = request_record.items.sole
    visit_request
    find("#item-#{line.id} [data-testid='edit-item']").click
    choose_product("Gel")
    expect(supplier_select.value).to eq(beta.id.to_s)
    expect(editor_row).to have_no_css("[data-supplier-kept-note]", visible: true)
  end

  it "invalid numbers keep the modal open and save nothing; Cancel closes it" do
    line = request_record.items.sole
    visit_request
    find("#item-#{line.id} [data-testid='edit-item']").click
    editor_row.find("[data-quantity-field]").fill_in(with: "-2")
    editor.find("[data-testid='item-editor-save']").click

    expect(editor).to be_visible
    expect(line.reload.quantity).to eq(4)
    editor.click_button I18n.t("common.cancel")
    expect(page).to have_no_css("[data-purchase-request-item-editor-target='modal']", visible: true)
  end

  it "deletes a row after confirmation (Arabic, RTL)" do
    gel_line = request_record.items.create!(product: gel, quantity: 1, unit_price: 20, supplier: beta)
    visit_request(locale: "ar")
    expect(page).to have_css("html[dir='rtl']")
    expect(page).to have_css("th", text: I18n.t("inventory.purchase_requests.items_actions", locale: :ar))

    within("#item-#{gel_line.id}") do
      accept_confirm(I18n.t("inventory.purchase_requests.item_delete_confirm", product: "Gel", locale: :ar)) do
        click_button I18n.t("inventory.purchase_requests.actions.delete_item", locale: :ar)
      end
    end
    expect(page).to have_text(I18n.t("inventory.purchase_requests.item_deleted", locale: :ar))
    expect(request_record.reload.items.map(&:product)).to eq([ shampoo ])
    expect(page).to have_no_css("#item-#{gel_line.id}")
  end
end
