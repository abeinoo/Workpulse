require "rails_helper"

# Receiving a Purchase Request whose lines name different suppliers. The
# request has ONE warehouse; a Goods Receipt receives ONE supplier group of its
# lines: one supplier's lines, or the lines without a supplier in their own
# receipt (PurchaseRequest#receiving_supplier_groups, enforced by GoodsReceipt /
# GoodsReceiptItem). Received / remaining quantities count confirmed,
# non-voided receipts only (PurchaseRequestItem#received_quantity). Legacy
# requests with a request-level supplier keep the locked-supplier behaviour
# (purchase_request_goods_receipt_spec.rb).
RSpec.describe "Purchase Request with several suppliers → Goods Receipts", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:approver)  { create(:user, business: business) }
  let!(:acme)     { business.suppliers.create!(name: "Acme") }
  let!(:beta)     { business.suppliers.create!(name: "Beta") }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:other_wh)  { business.warehouses.create!(name: "Branch") }
  let!(:product_a) { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }
  let!(:product_b) { business.products.create!(name: "Product B", sku: "B-1", average_cost_price: 200) }
  let!(:product_c) { business.products.create!(name: "Product C", sku: "C-1", average_cost_price: 50) }

  # A: 10 × 100 from Acme, B: 4 × 200 from Beta, C: 2 × 50 with no supplier.
  let(:request) do
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: owner)
    pr.items.build(product: product_a, quantity: 10, unit_price: 100, supplier: acme)
    pr.items.build(product: product_b, quantity: 4, unit_price: 200, supplier: beta)
    pr.items.build(product: product_c, quantity: 2, unit_price: 50)
    pr.save!
    pr.update_columns(status: "pending_approval", submitted_by_id: owner.id)
    Inventory::PurchaseRequestApproval.new(purchase_request_id: pr.id, actor: owner).approve!
    pr.reload
  end

  def line(product) = request.items.find_by!(product: product)

  def receipt_params(supplier, lines, warehouse_id: warehouse.id)
    {
      goods_receipt: {
        purchase_request_id: request.id, warehouse_id: warehouse_id, supplier_id: supplier&.id,
        received_on: Date.current.to_s, funding_source_kind: "supplier_credit",
        items_attributes: lines.each_with_index.to_h do |(product, qty), i|
          [ i.to_s, { product_id: product.id, quantity: qty, unit_cost: line(product).unit_price,
                      purchase_request_item_id: line(product).id } ]
        end
      }
    }
  end

  def prefilled_product_ids
    Nokogiri::HTML(response.body).css("input[name*='[purchase_request_item_id]']").map do |input|
      PurchaseRequestItem.find(input["value"]).product_id
    end
  end

  def confirm!(receipt)
    receipt.update_column(:approval_status, "approved")
    result = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: owner).call
    raise result.error unless result.ok?
  end

  before { sign_in owner }

  describe "GET /inventory/goods_receipts/new?purchase_request_id=" do
    it "asks which supplier the receipt is for when several suppliers have outstanding lines" do
      get new_inventory_goods_receipt_path(purchase_request_id: request.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("inventory.goods_receipts.choose_supplier_title"))
      links = Nokogiri::HTML(response.body).css("a.btn").to_h { |a| [ a.text.strip, a["href"] ] }
      expect(links.keys).to include("Acme", "Beta", I18n.t("inventory.goods_receipts.no_supplier_lines"))
      expect(links["Acme"]).to include("supplier_id=#{acme.id}")
      expect(GoodsReceipt.count).to eq(0)
    end

    it "supplier A: only A's lines, in the request's warehouse — never B's or the lines without a supplier" do
      get new_inventory_goods_receipt_path(purchase_request_id: request.id, supplier_id: acme.id)

      doc = Nokogiri::HTML(response.body)
      expect(prefilled_product_ids).to contain_exactly(product_a.id)
      expect(doc.at_css("[data-testid='gr-selected-supplier-name']").text.strip).to eq("Acme")
      expect(doc.at_css('input[type="hidden"][name="goods_receipt[supplier_id]"]')["value"]).to eq(acme.id.to_s)
      expect(doc.at_css('select[name="goods_receipt[supplier_id]"]')["disabled"]).to be_present
      expect(response.body).to include(I18n.t("inventory.goods_receipts.supplier_line_locked_hint"))
      expect(doc.at_css('select[name="goods_receipt[warehouse_id]"] option[selected]')["value"]).to eq(warehouse.id.to_s)
      # The other suppliers stay one click away.
      expect(doc.css("a").map { |a| a["href"] }).to include(
        new_inventory_goods_receipt_path(purchase_request_id: request.id, supplier_id: beta.id)
      )
    end

    it "supplier B: only B's lines" do
      get new_inventory_goods_receipt_path(purchase_request_id: request.id, supplier_id: beta.id)

      expect(prefilled_product_ids).to contain_exactly(product_b.id)
      expect(Nokogiri::HTML(response.body).at_css("[data-testid='gr-selected-supplier-name']").text.strip).to eq("Beta")
    end

    it "receives only the lines without a supplier under \"none\", with an editable supplier" do
      get new_inventory_goods_receipt_path(purchase_request_id: request.id, supplier_id: "none")

      expect(prefilled_product_ids).to contain_exactly(product_c.id)
      expect(Nokogiri::HTML(response.body).at_css('select[name="goods_receipt[supplier_id]"]')["disabled"]).to be_nil
    end

    it "ignores a supplier with no outstanding lines and asks again" do
      stranger = business.suppliers.create!(name: "Stranger")

      get new_inventory_goods_receipt_path(purchase_request_id: request.id, supplier_id: stranger.id)

      expect(response.body).to include(I18n.t("inventory.goods_receipts.choose_supplier_title"))
    end

    it "skips the choice when only one supplier group still has outstanding lines" do
      single = business.purchase_requests.build(warehouse: warehouse, created_by: owner)
      single.items.build(product: product_a, quantity: 1, unit_price: 100, supplier: acme)
      single.save!
      single.update_column(:status, "approved")

      get new_inventory_goods_receipt_path(purchase_request_id: single.id)

      expect(response.body).not_to include(I18n.t("inventory.goods_receipts.choose_supplier_title"))
      expect(Nokogiri::HTML(response.body).at_css('input[type="hidden"][name="goods_receipt[supplier_id]"]')["value"]).to eq(acme.id.to_s)
    end

    it "one supplier plus lines without a supplier are two groups: asks which" do
      single = business.purchase_requests.build(warehouse: warehouse, created_by: owner)
      single.items.build(product: product_a, quantity: 1, unit_price: 100, supplier: acme)
      single.items.build(product: product_c, quantity: 1, unit_price: 50)
      single.save!
      single.update_column(:status, "approved")

      get new_inventory_goods_receipt_path(purchase_request_id: single.id)

      expect(response.body).to include(I18n.t("inventory.goods_receipts.choose_supplier_title"))
    end

    it "shows each line's ordered / received / remaining and offers only what remains (EN and AR)" do
      post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 6 ] ])
      confirm!(GoodsReceipt.last)

      { "en" => %w[Ordered Received Remaining], "ar" => %w[المطلوب المستلم المتبقي] }.each do |locale, headings|
        owner.update!(preferred_locale: locale)
        get new_inventory_goods_receipt_path(purchase_request_id: request.id, supplier_id: acme.id)
        doc = Nokogiri::HTML(response.body)

        expect(doc.css("table[data-testid='gr-items-table'] thead th").map { |th| th.text.squish }).to include(*headings)
        row = doc.at_css("[data-testid='gr-request-line'][data-purchase-request-item-id='#{line(product_a).id}']")
        expect(%w[ordered received remaining].map { |c| row.at_css("[data-testid='gr-line-#{c}']").text.squish })
          .to eq(%w[10 6 4])
        expect(row.at_css("input[name$='[quantity]']")["max"].to_d).to eq(4) # never more than remains
        expect(doc.at_css("html")["dir"]).to eq(locale == "ar" ? "rtl" : "ltr")
      end
    end
  end

  describe "remaining quantities across several receipts" do
    def remaining = request.items.reload.to_h { |item| [ item.product_id, item.remaining_quantity.to_i ] }

    it "partial receipts reduce only their own lines; a fully received line is never offered or accepted again" do
      post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 6 ] ])
      confirm!(GoodsReceipt.last)
      expect(remaining).to eq(product_a.id => 4, product_b.id => 4, product_c.id => 2) # Beta's and unassigned untouched

      post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 4 ] ])
      confirm!(GoodsReceipt.last)
      expect(remaining).to eq(product_a.id => 0, product_b.id => 4, product_c.id => 2)

      # Acme has nothing left: it is no longer offered, and a direct POST is refused.
      get new_inventory_goods_receipt_path(purchase_request_id: request.id)
      links = Nokogiri::HTML(response.body).css("a.btn").map(&:text).map(&:strip)
      expect(links).to include("Beta", I18n.t("inventory.goods_receipts.no_supplier_lines"))
      expect(links).not_to include("Acme")

      expect {
        post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 1 ] ])
      }.not_to change(GoodsReceipt, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "draft and voided receipts never count as received" do
      post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 3 ] ]) # stays a draft
      post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 5 ] ])
      voided = GoodsReceipt.last
      confirm!(voided)
      expect(remaining[product_a.id]).to eq(5)

      result = Inventory::GoodsReceiptVoider.new(goods_receipt_id: voided.id, actor: owner, reason: "wrong delivery").call
      expect(result).to be_ok, result.error
      expect(remaining[product_a.id]).to eq(10)
    end
  end

  describe "validation errors" do
    it "re-render with the selected supplier, its lines only and the submitted quantities" do
      post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 11 ] ])

      expect(response).to have_http_status(:unprocessable_entity)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-testid='gr-selected-supplier-name']").text.strip).to eq("Acme")
      expect(doc.at_css('input[type="hidden"][name="goods_receipt[supplier_id]"]')["value"]).to eq(acme.id.to_s)
      expect(prefilled_product_ids).to eq([ product_a.id ])
      expect(doc.at_css("input[name$='[quantity]']")["value"]).to eq("11")
      expect(doc.css("[data-testid='gr-switch-supplier']").map { |a| a.text.strip }).to include("Beta")
    end
  end

  describe "POST /inventory/goods_receipts" do
    it "rejects receiving a line against a different supplier" do
      expect {
        post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 1 ], [ product_b, 1 ] ])
      }.not_to change(GoodsReceipt, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(ERB::Util.html_escape(
        I18n.t("activerecord.errors.models.goods_receipt_item.attributes.purchase_request_item.supplier_mismatch")
      ))
    end

    it "rejects a supplier-line on a receipt without a supplier" do
      expect {
        post inventory_goods_receipts_path, params: receipt_params(nil, [ [ product_a, 1 ] ])
      }.not_to change(GoodsReceipt, :count)
    end

    it "rejects mixing a supplier's lines with the lines without a supplier (direct POST)" do
      expect {
        post inventory_goods_receipts_path, params: receipt_params(beta, [ [ product_b, 1 ], [ product_c, 1 ] ])
      }.not_to change(GoodsReceipt, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(ERB::Util.html_escape(
        I18n.t("activerecord.errors.models.goods_receipt.attributes.base.purchase_request_mixed_supplier_groups")
      ))
    end

    it "never re-judges a receipt saved before the rule (no line changes): it still saves" do
      historical = business.goods_receipts.build(purchase_request: request, supplier: beta, warehouse: warehouse,
                                                 received_on: Date.current, funding_source_kind: "supplier_credit")
      historical.items.build(product: product_b, quantity: 1, unit_cost: 200, purchase_request_item: line(product_b))
      historical.save!
      # The unassigned line as a receipt saved before the rule would hold it.
      GoodsReceiptItem.new(goods_receipt: historical, product: product_c, quantity: 1, unit_cost: 50,
                           purchase_request_item: line(product_c)).save!(validate: false)

      historical = GoodsReceipt.find(historical.id)
      historical.notes = "checked"
      expect(historical.save).to be(true)

      historical.items.build(product: product_a, quantity: 1, unit_cost: 100, purchase_request_item: line(product_a))
      expect(historical.save).to be(false) # changing its lines applies the rule
    end

    it "accepts the lines without a supplier in their own receipt, with the actual supplier recorded" do
      expect {
        post inventory_goods_receipts_path, params: receipt_params(beta, [ [ product_c, 1 ] ])
      }.to change(GoodsReceipt, :count).by(1)
    end

    it "receives the request fully through per-supplier and partial receipts, into the request's warehouse" do
      post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 6 ] ])
      confirm!(GoodsReceipt.last)
      expect(request.reload).to be_partially_received

      post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 4 ] ])
      confirm!(GoodsReceipt.last)
      post inventory_goods_receipts_path, params: receipt_params(beta, [ [ product_c, 2 ] ]) # actual supplier recorded
      confirm!(GoodsReceipt.last)
      expect(request.reload).to be_partially_received

      # Acme and the unassigned lines are done: only Beta remains, so the page no longer asks.
      get new_inventory_goods_receipt_path(purchase_request_id: request.id)
      expect(prefilled_product_ids).to contain_exactly(product_b.id)

      post inventory_goods_receipts_path, params: receipt_params(beta, [ [ product_b, 4 ] ])
      confirm!(GoodsReceipt.last)

      expect(request.reload).to be_fully_received
      expect(request.goods_receipts.map(&:supplier)).to contain_exactly(acme, acme, beta, beta)
      expect(line(product_c).supplier_id).to be_nil # the unassigned line stays unassigned
      expect(InventoryMovement.where(product: [ product_a, product_b, product_c ]).pluck(:warehouse_id).uniq).to eq([ warehouse.id ])
      expect(product_a.reload.current_stock).to eq(10)
      expect(product_b.reload.current_stock).to eq(4)
    end

    it "still rejects receiving more than a line's remaining quantity" do
      post inventory_goods_receipts_path, params: receipt_params(acme, [ [ product_a, 11 ] ])

      expect(response).to have_http_status(:unprocessable_entity)
      expect(GoodsReceipt.count).to eq(0)
    end
  end

  describe "advances" do
    def approve_beta_receipt
      post inventory_goods_receipts_path, params: receipt_params(beta, [ [ product_b, 1 ] ])
      receipt = GoodsReceipt.last
      receipt.update_column(:approval_status, "pending_approval")
      expect(Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: approver).approve!).to be_ok
      receipt.reload
    end

    it "a historical (legacy) supplier-payment advance is applied to the first approved receipt, whichever supplier" do
      legacy_confirmed_advance(request: request, amount: 300, actor: owner, reference: "DEP-1")

      expect(approve_beta_receipt.financial_settlements.advance_applications.sum(:amount)).to eq(200)
      expect(request.reload.unapplied_advances_total).to eq(100)
    end

    it "a funding advance (the responsible employee's custody) is never deducted at receiving" do
      responsible = purchaser_with_custody(business, first_name: "Rami")
      request.update!(responsible_employee: responsible)
      funded = Inventory::PurchaseRequestAdvanceRecorder.new(
        purchase_request_id: request.id, actor: owner,
        params: { amount: 300, source_kind: "company_cash", paid_on: Date.current, reference: "DEP-1" }
      ).call
      expect(funded).to be_ok # posted when recorded

      expect(approve_beta_receipt.financial_settlements.advance_applications).to be_empty
      expect(custody_of(responsible).reload.current_balance).to eq(300)
    end
  end
end
