require "rails_helper"

RSpec.describe "Stock issue import — CSV and Excel (browser)", type: :system do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:branch)    { business.branches.create!(name: "Main Branch", active: true) }
  let!(:uyn1)      { business.products.create!(name: "أعواد خشبية كبيرة", sku: "UYN1", initial_cost_price: 30, average_cost_price: 30) }
  let!(:abc)       { business.products.create!(name: "Widget", sku: "ABC123", initial_cost_price: 10, average_cost_price: 10) }

  before do
    [ uyn1, abc ].each do |product|
      r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      r.items.build(product: product, quantity: 20, unit_cost: 10)
      Inventory::GoodsReceiptPoster.new(r).call
    end
    sign_in owner
  end

  after { FileUtils.rm_rf(Rails.root.join("tmp", "import_specs")) }

  def mapping_t(key, **) = I18n.t("inventory.imports.mapping.#{key}", **)

  def temp_file(name, bytes)
    dir = Rails.root.join("tmp", "import_specs")
    FileUtils.mkdir_p(dir)
    path = dir.join("#{SecureRandom.hex(4)}-#{name}")
    File.binwrite(path, bytes)
    path.to_s
  end

  def upload(path, notes: nil)
    visit import_inventory_stock_issues_path
    expect(page).not_to have_select("mapping_sku") # no mapping before a file is uploaded
    select warehouse.name, from: "warehouse_id"
    select branch.name,    from: "branch_id"
    fill_in "notes", with: notes if notes
    attach_file "file", path
    click_button mapping_t("continue_to_mapping")
  end

  def preview_rows = all("#preview-rows tbody tr").map { |tr| tr.all("td").map { |td| td.text.squish }.first(4) }

  it "the Stock Issues index button opens the import page" do
    owner.update!(preferred_locale: "ar")
    visit inventory_stock_issues_path
    expect(page).to have_link("إذن صرف جديد")

    click_link "استيراد إذن صرف"
    expect(page).to have_current_path(import_inventory_stock_issues_path)
    expect(page).to have_field("file")
  end

  it "CSV: map columns, fix a missing mapping, preview and import" do
    csv = "Location,SKU,Qty ordered,Total cost\nMain,UYN1,2,70\nMain,ABC123,5,50\n"
    upload(temp_file("export.csv", csv), notes: "صرف مستلزمات للفرع لتغطية احتياج الأسبوع")

    expect(page).to have_css("#upload-success", text: mapping_t("upload_success"))
    expect(page).to have_select("mapping_sku", selected: "SKU")
    expect(page).to have_select("mapping_quantity", selected: "Qty ordered")
    expect(preview_rows).to eq([ [ "2", "UYN1", "أعواد خشبية كبيرة", "2" ], [ "3", "ABC123", "Widget", "5" ] ])

    # Un-mapping a required field disables Import immediately (client side)…
    select mapping_t("ignore_column"), from: "mapping_quantity"
    expect(page).to have_button(mapping_t("import"), disabled: true)
    expect(page).to have_content(mapping_t("stale_preview"))

    # …and the server insists on it too.
    click_button mapping_t("update_preview")
    expect(page).to have_css("#mapping-required", text: mapping_t("required_summary"))
    expect(page).to have_button(mapping_t("import"), disabled: true)

    select "Qty ordered", from: "mapping_quantity"
    click_button mapping_t("update_preview")
    expect(page).to have_css("#preview-valid-count", text: "2")

    click_button mapping_t("import")
    expect(page).to have_content(I18n.t("inventory.imports.submitted_for_approval"))
    expect(page).to have_css("#stock-not-deducted-notice")
    issue = business.stock_issues.last
    expect(issue).to be_pending_approval
    expect(issue.inventory_movements).to be_empty
    # The form's note survives the mapping round-trips and lands on the issue.
    expect(issue.notes).to eq("صرف مستلزمات للفرع لتغطية احتياج الأسبوع")
    expect(issue.items.order(:id).map { |i| [ i.product.sku, i.quantity.to_i ] }).to eq([ [ "UYN1", 2 ], [ "ABC123", 5 ] ])
  end

  it "XLSX: Arabic headers in another order are matched, previewed and imported" do
    bytes = xlsx_bytes([ [ "ملاحظات", "الكمية", "كود الصنف" ], [ "عاجل", "3", "ABC123" ] ], types: [ :string, :string, :string ])
    upload(temp_file("stock.xlsx", bytes))

    expect(page).to have_select("mapping_sku", selected: "كود الصنف")
    expect(page).to have_select("mapping_quantity", selected: "الكمية")
    expect(preview_rows).to eq([ [ "2", "ABC123", "Widget", "3" ] ])

    click_button mapping_t("import")
    expect(page).to have_content(I18n.t("inventory.imports.submitted_for_approval"))
    expect(business.stock_issues.last.items.sole).to have_attributes(product: abc, quantity: 3)
  end

  it "shows row errors, blocks Import, and offers fix-later explicitly" do
    upload(temp_file("bad.csv", "SKU,Quantity\nUYN1,2\nUYN1,abc\nNOPE,1\n"))

    # Badges are uppercased by CSS, so reasons are matched case-insensitively.
    errors = all("#preview-errors tbody tr").map { |tr| tr.all("td").map { |td| td.text.squish } }
    expect(errors.map { |cells| [ cells.first, cells.last.downcase ] }).to eq([
      [ "3", mapping_t("row_errors.invalid_quantity").downcase ],
      [ "4", mapping_t("row_errors.unknown_sku").downcase ]
    ])
    expect(page).to have_button(mapping_t("import"), disabled: true)
    expect(page).to have_link(mapping_t("upload_corrected_file"))

    click_button mapping_t("import_partial")
    expect(page).to have_content(I18n.t("inventory.imports.draft_batch_title"))
    expect(business.stock_issue_import_batches.last.rows.count).to eq(2)
  end

  it "Arabic RTL: the upload page and mapping step render right-to-left" do
    owner.update!(preferred_locale: "ar")
    I18n.with_locale(:ar) do
      upload(temp_file("stock.csv", "SKU,Quantity\nUYN1,1\n"))

      # The upload is a full page load (data-turbo: false) and the upload page is
      # RTL too: wait for the mapping step before checking the document, or the
      # html[dir=rtl] check can match the page being left (BUG-011).
      expect(page).to have_select("mapping_sku")
      expect(page).to have_css("html[dir=rtl]")
      expect(page).to have_content("تم تحميل الملف بنجاح. اختر الأعمدة المطابقة للحقول المطلوبة.")
      expect(page).to have_button("استيراد إذن الصرف", disabled: false)
    end
  end
end
