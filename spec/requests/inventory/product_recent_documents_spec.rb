require "rails_helper"

# Product page: latest goods receipt + latest 5 stock issues carrying the
# product, linked to their documents (Inventory::ProductRecentDocuments).
RSpec.describe "Product page — recent goods receipts and stock issues", type: :request do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main Warehouse") }
  let(:branch)    { create(:branch, business: business, name: "Downtown Salon") }
  let(:supplier)  { business.suppliers.create!(name: "Cairo Beauty Supplies") }
  let(:admin)     { create(:user, :super_admin, business: business) }
  let(:requester) { create(:user, business: business, first_name: "Mona", last_name: "Adel") }

  let(:product) { business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0) }
  let(:other)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0) }

  def receipt(on: Date.current, lines: { product => 5 }, approval_status: "pending_approval", wh: warehouse)
    r = business.goods_receipts.build(warehouse: wh, supplier: supplier, received_on: on, funding_source_kind: "supplier_credit")
    lines.each { |p, qty| r.items.build(product: p, quantity: qty, unit_cost: 10) }
    r.save!
    r.update_column(:approval_status, approval_status)
    r.reload
  end

  def approve(r) = expect(Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).approve!).to(be_ok)

  def received_receipt(**opts)
    receipt(**opts).tap do |r|
      approve(r)
      expect(Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: admin).call).to be_ok
    end.reload
  end

  def issue(on: Date.current, lines: { product => 2 }, status: "draft", wh: warehouse, by: requester)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: on, created_by: by)
    lines.each { |p, qty| i.items.build(product: p, quantity: qty) }
    i.save!
    save_stock_issue_in_status!(i, status) unless status == "draft"
    i.reload
  end

  def posted_issue(**opts)
    issue(**opts).tap { |i| expect(approve_and_post_stock_issue(i)).to be_ok }.reload
  end

  def page = Nokogiri::HTML(response.body)
  def section(id) = page.at_css("##{id}")
  def rows(id) = section(id).css("tbody tr[data-recent-document]")
  def numbers(id) = rows(id).map { |tr| tr["data-recent-document"] }
  def row(id, number) = section(id).at_css("tr[data-recent-document='#{number}']")
  def effect(id, number) = row(id, number).at_css("[data-stock-effect]")["data-stock-effect"]

  def visit_product(user = admin, locale: nil)
    sign_in user
    user.update_column(:preferred_locale, locale) if locale
    get inventory_product_path(product)
    expect(response).to have_http_status(:ok)
  end

  describe "recent goods receipts" do
    it "shows the latest receipt carrying the product, linked to its page, with this product's quantity" do
      received_receipt(on: 3.days.ago.to_date)
      latest = receipt(on: 1.day.ago.to_date, lines: { product => 7, other => 40 })
      receipt(on: Date.current, lines: { other => 9 }) # newer, but without this product

      visit_product
      expect(numbers("recent-goods-receipts")).to eq([ latest.receipt_number ])

      tr = row("recent-goods-receipts", latest.receipt_number)
      link = tr.at_css("a[href='#{inventory_goods_receipt_path(latest)}']")
      expect(link.text.strip).to eq(latest.receipt_number)
      expect(tr.text).to include("Cairo Beauty Supplies", "Main Warehouse", "7")
      expect(tr.text).not_to include("40")
      expect(tr.text).to include(I18n.t("inventory.goods_receipts.approval_statuses.pending_approval"),
                                 I18n.t("inventory.goods_receipts.receipt_statuses.not_received"))
    end

    it "sums the product's lines when it appears more than once on a receipt" do
      r = receipt(lines: { product => 3 })
      r.items.create!(product: product, quantity: 4, unit_cost: 10)

      visit_product
      expect(row("recent-goods-receipts", r.receipt_number).at_css("[data-stock-effect]").text).to include("7")
    end

    it "orders same-day receipts deterministically by id" do
      first  = receipt(on: Date.current)
      second = receipt(on: Date.current)
      visit_product
      expect(numbers("recent-goods-receipts")).to eq([ [ first, second ].max_by(&:id).receipt_number ])
    end

    it "marks a received receipt as added to stock" do
      r = received_receipt
      visit_product
      expect(effect("recent-goods-receipts", r.receipt_number)).to eq("posted")
      expect(row("recent-goods-receipts", r.receipt_number).text)
        .to include("+5", I18n.t("inventory.products.recent_documents.stock_effects.in.posted"))
    end

    it "labels a rejected receipt accurately and never as a stock movement" do
      r = receipt
      Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).reject!(reason: "wrong supplier")

      visit_product
      tr = row("recent-goods-receipts", r.receipt_number)
      expect(tr.text).to include(I18n.t("inventory.goods_receipts.approval_statuses.rejected"),
                                 I18n.t("inventory.goods_receipts.receipt_statuses.not_receivable"),
                                 I18n.t("inventory.products.recent_documents.stock_effects.in.not_posted"))
      expect(effect("recent-goods-receipts", r.receipt_number)).to eq("not_posted")
      expect(tr.text).not_to include("+5")
    end

    it "labels a cancelled receipt accurately and never as a stock movement" do
      r = receipt
      Inventory::GoodsReceiptVoider.new(goods_receipt_id: r.id, actor: admin, reason: "duplicate").call

      visit_product
      tr = row("recent-goods-receipts", r.receipt_number)
      expect(tr.text).to include(I18n.t("inventory.goods_receipts.approval_statuses.cancelled"),
                                 I18n.t("inventory.goods_receipts.receipt_statuses.voided"))
      expect(effect("recent-goods-receipts", r.receipt_number)).to eq("not_posted")
    end

    it "shows a voided received receipt as reversed, not as a completed movement" do
      r = received_receipt
      expect(Inventory::DocumentVoider.new(r, user: admin, reason: "mistake").call).to be_ok

      visit_product
      expect(effect("recent-goods-receipts", r.receipt_number)).to eq("reversed")
      expect(row("recent-goods-receipts", r.receipt_number).text)
        .to include(I18n.t("inventory.products.recent_documents.stock_effects.in.reversed"))
    end

    it "shows the empty state when the product was never received" do
      receipt(lines: { other => 3 })
      visit_product
      expect(rows("recent-goods-receipts")).to be_empty
      expect(section("recent-goods-receipts").css("table")).to be_empty
      expect(section("recent-goods-receipts").text).to include(I18n.t("inventory.products.no_recent_goods_receipts"))
    end
  end

  describe "recent stock issues" do
    it "shows the latest 5 issues carrying the product, newest first, each linked" do
      issues = (0..6).map { |n| issue(on: (10 - n).days.ago.to_date) }
      issue(on: Date.current, lines: { other => 1 }) # newest, but without this product

      visit_product
      expected = issues.last(5).reverse
      expect(numbers("recent-stock-issues")).to eq(expected.map(&:issue_number))
      expected.each do |i|
        expect(row("recent-stock-issues", i.issue_number).at_css("a[href='#{inventory_stock_issue_path(i)}']").text.strip)
          .to eq(i.issue_number)
      end
    end

    it "shows this product's quantity, warehouse, destination branch and requester" do
      i = issue(lines: { product => 3, other => 50 })
      visit_product
      tr = row("recent-stock-issues", i.issue_number)
      expect(tr.at_css("[data-stock-effect]").text).to include("3")
      expect(tr.text).not_to include("50")
      expect(tr.text).to include("Main Warehouse", "Downtown Salon", "Mona Adel")
    end

    it "marks an issued document as deducted from stock" do
      received_receipt(lines: { product => 10 })
      i = posted_issue
      visit_product
      expect(effect("recent-stock-issues", i.issue_number)).to eq("posted")
      expect(row("recent-stock-issues", i.issue_number).text)
        .to include("−2", I18n.t("inventory.stock_issues.statuses.issued"),
                    I18n.t("inventory.products.recent_documents.stock_effects.out.posted"))
    end

    it "keeps rejected and cancelled issues visible but never as stock movements" do
      rejected  = issue(status: "pending_approval")
      Inventory::StockIssueApproval.new(stock_issue_id: rejected.id, actor: admin).reject!(reason: "not needed")
      cancelled = issue
      expect(Inventory::StockIssueCancellation.new(stock_issue_id: cancelled.id, actor: admin, reason: "dup").call).to be_ok
      approved  = issue(status: "approved")

      visit_product
      { rejected => "rejected", cancelled => "cancelled", approved => "approved" }.each do |i, status|
        tr = row("recent-stock-issues", i.issue_number)
        expect(tr.text).to include(I18n.t("inventory.stock_issues.statuses.#{status}"))
        expect(effect("recent-stock-issues", i.issue_number)).to eq("not_posted")
        expect(tr.text).not_to include("−2")
      end
    end

    it "shows a voided issue as returned to stock" do
      received_receipt(lines: { product => 10 })
      i = posted_issue
      expect(Inventory::DocumentVoider.new(i, user: admin, reason: "mistake").call).to be_ok

      visit_product
      tr = row("recent-stock-issues", i.issue_number)
      expect(tr.text).to include(I18n.t("inventory.void.status_voided"),
                                 I18n.t("inventory.products.recent_documents.stock_effects.out.reversed"))
      expect(effect("recent-stock-issues", i.issue_number)).to eq("reversed")
    end

    it "links View all to the movements report filtered to this product's stock issues" do
      issue
      visit_product
      expect(section("recent-stock-issues").at_css("#recent-stock-issues-view-all")["href"])
        .to eq(inventory_movements_report_path(product_id: product.id, reason: "stock_issue"))
    end

    it "shows the empty state without a View all link when nothing was issued" do
      issue(lines: { other => 1 })
      visit_product
      expect(rows("recent-stock-issues")).to be_empty
      expect(section("recent-stock-issues").at_css("#recent-stock-issues-view-all")).to be_nil
      expect(section("recent-stock-issues").text).to include(I18n.t("inventory.products.no_recent_stock_issues"))
    end

    it "keeps an import still being resolved out of the list, like the stock issues index" do
      draft = issue
      StockIssueImportBatch.create!(business: business, warehouse: warehouse, branch: branch, stock_issue: draft)
      visit_product
      expect(numbers("recent-stock-issues")).not_to include(draft.issue_number)
    end
  end

  describe "authorization" do
    let(:other_warehouse) { business.warehouses.create!(name: "Remote Warehouse") }

    def viewer(*permissions, warehouses: [])
      role = business.permission_roles.create!(name: "Viewer #{SecureRandom.hex(3)}", permissions: permissions)
      create(:user, business: business).tap do |u|
        u.update_column(:permission_role_id, role.id)
        warehouses.each { |wh| WarehouseAssignment.create!(user: u, warehouse: wh) }
      end
    end

    it "only lists documents from warehouses a warehouse-scoped user can open" do
      mine   = receipt(on: 2.days.ago.to_date)
      theirs = receipt(on: Date.current, wh: other_warehouse)
      issue_mine   = issue(on: 2.days.ago.to_date)
      issue_theirs = issue(on: Date.current, wh: other_warehouse)

      visit_product(viewer("view_inventory", warehouses: [ warehouse ]))
      expect(numbers("recent-goods-receipts")).to eq([ mine.receipt_number ])
      expect(numbers("recent-stock-issues")).to eq([ issue_mine.issue_number ])
      new_sections = section("recent-goods-receipts").to_html + section("recent-stock-issues").to_html
      expect(new_sections).not_to include(theirs.receipt_number, issue_theirs.issue_number,
                                          inventory_goods_receipt_path(theirs), inventory_stock_issue_path(issue_theirs))

      # …and every link shown actually opens for that user.
      get inventory_goods_receipt_path(mine)
      expect(response).to have_http_status(:ok)
      get inventory_stock_issue_path(issue_mine)
      expect(response).to have_http_status(:ok)
    end

    it "never shows another business's documents, even if a line points at this product" do
      foreign = create(:business)
      fw = foreign.warehouses.create!(name: "Foreign")
      fp = foreign.products.create!(name: "Foreign", sku: "F-1", initial_cost_price: 0, average_cost_price: 0)
      fr = foreign.goods_receipts.build(warehouse: fw, received_on: Date.current, funding_source_kind: "supplier_credit")
      fr.items.build(product: fp, quantity: 1, unit_cost: 1)
      fr.save!
      fr.items.first.update_column(:product_id, product.id)

      visit_product
      expect(rows("recent-goods-receipts")).to be_empty
      expect(response.body).not_to include(inventory_goods_receipt_path(fr))
    end

    it "is not reachable by a user without inventory access" do
      sign_in create(:user, business: business)
      get inventory_product_path(product)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "query count" do
    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end

    def load_recent
      recent = Inventory::ProductRecentDocuments.new(product, goods_receipts: GoodsReceipt.for_business(business),
                                                              stock_issues:   StockIssue.for_business(business))
      rows = recent.goods_receipts + recent.stock_issues
      # Touch everything the partials render.
      rows.each do |row|
        doc = row.document
        doc.warehouse.name
        doc.is_a?(GoodsReceipt) ? doc.supplier&.name : [ doc.branch&.name, doc.created_by&.full_name ]
      end
    end

    it "loads both sections in a fixed number of queries, however long the history" do
      received_receipt
      issue
      few = count_queries { load_recent }

      8.times { |n| receipt(on: (n + 1).days.ago.to_date, lines: { product => 1, other => 1 }) }
      12.times { |n| issue(on: (n + 1).days.ago.to_date, lines: { product => 1, other => 1 }, by: create(:user, business: business)) }
      expect(count_queries { load_recent }).to eq(few)
    end

    it "does not add per-row queries to the product page" do
      sign_in admin
      issue
      get inventory_product_path(product) # warm up
      few = count_queries { get inventory_product_path(product) }

      6.times { issue(lines: { product => 1, other => 1 }, by: create(:user, business: business)) }
      expect(count_queries { get inventory_product_path(product) }).to eq(few)
    end
  end

  describe "Arabic / RTL" do
    it "renders the sections in Arabic with RTL direction and mobile card labels" do
      i = issue
      receipt
      visit_product(locale: "ar")

      expect(page.at_css("html")["dir"]).to eq("rtl")
      expect(section("recent-goods-receipts").at_css("h2").text).to eq("آخر أذونات الاستلام")
      expect(section("recent-stock-issues").at_css("h2").text).to eq("آخر أذونات الصرف")
      expect(section("recent-goods-receipts").to_html + section("recent-stock-issues").to_html)
        .not_to match(/translation[ _]missing/i)

      expect(section("recent-stock-issues").at_css(".table-wrap.table-wrap--cards")).to be_present
      labels = row("recent-stock-issues", i.issue_number).css("td").map { |td| td["data-label"] }
      expect(labels).to all(be_present)
      expect(labels).to include("الكمية", "الحالة")
    end

    it "shows the Arabic empty states" do
      visit_product(locale: "ar")
      expect(section("recent-goods-receipts").text).to include("لا توجد أذونات استلام لهذا المنتج")
      expect(section("recent-stock-issues").text).to include("لا توجد أذونات صرف لهذا المنتج")
    end
  end
end
