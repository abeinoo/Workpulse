require "rails_helper"

# A Goods Receipt created from a Purchase Request records what was ACTUALLY
# bought: the request's lines (suggested) plus any extra catalog products
# bought beyond it. Extras are lines with no purchase_request_item — they are
# added to the receipt only; the Purchase Request (its lines, received /
# remaining quantities and status) is never changed by them.
#
# The remaining-quantity guard still holds: a product that IS on the request
# must be received through its request line (an unreferenced line for it is
# refused), so stripping the reference can't bypass the guard.
RSpec.describe "Goods receipt from a Purchase Request — extra products", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business, preferred_locale: "ar") }
  let(:supplier)  { business.suppliers.create!(name: "مورد مستحضرات") }
  let(:warehouse) { business.warehouses.create!(name: "المستودع الرئيسي") }

  def product(name, sku) = business.products.create!(name: name, sku: sku, average_cost_price: 10)

  let!(:shampoo) { product("شامبو", "SH-1") }
  let!(:mask)    { product("ماسك شعر", "MS-1") }
  let!(:cream)   { product("كريم شعر", "CR-1") }
  let!(:oil)     { product("زيت شعر", "OL-1") }

  let!(:pr) do
    request = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
    request.items.build(product: shampoo, quantity: 10, unit_price: 20, source_warehouse: warehouse)
    request.items.build(product: mask,    quantity: 5,  unit_price: 30, source_warehouse: warehouse)
    request.save!
    request.update_columns(status: "pending_approval", submitted_by_id: owner.id)
    Inventory::PurchaseRequestApproval.new(purchase_request_id: request.id, actor: owner).approve!
    request.reload
  end

  let(:pri_shampoo) { pr.items.find_by!(product: shampoo) }
  let(:pri_mask)    { pr.items.find_by!(product: mask) }

  before { sign_in owner }

  def request_line(pri, quantity, unit_cost)
    { product_id: pri.product_id, quantity: quantity, unit_cost: unit_cost, purchase_request_item_id: pri.id }
  end

  def extra_line(product, quantity, unit_cost) = { product_id: product.id, quantity: quantity, unit_cost: unit_cost }

  def create_receipt(*lines, purchase_request: pr)
    post inventory_goods_receipts_path, params: {
      goods_receipt: {
        purchase_request_id: purchase_request&.id, warehouse_id: warehouse.id, supplier_id: supplier.id,
        received_on: Date.current.to_s, funding_source_kind: "supplier_credit",
        items_attributes: lines.each_with_index.to_h { |line, i| [ i.to_s, line ] }
      }
    }
    business.goods_receipts.order(:id).last
  end

  def pr_snapshot
    pr.reload
    { status: pr.status, lines: pr.items.order(:id).map { |i| i.attributes.slice("product_id", "quantity", "unit_price") },
      count: pr.items.count }
  end

  describe "A. only the request's products" do
    it "creates the receipt as before" do
      receipt = create_receipt(request_line(pri_shampoo, 10, 20), request_line(pri_mask, 5, 30))

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.purchase_request).to eq(pr)
      expect(receipt.items.map(&:purchase_request_item)).to contain_exactly(pri_shampoo, pri_mask)
    end
  end

  describe "B. one extra product outside the request" do
    it "is accepted and kept as an unreferenced line" do
      receipt = create_receipt(request_line(pri_shampoo, 10, 20), request_line(pri_mask, 5, 30),
                               extra_line(cream, 3, 15))

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      extra = receipt.items.find_by!(product: cream)
      expect(extra).to have_attributes(quantity: 3, unit_cost: 15, purchase_request_item_id: nil)
    end
  end

  describe "C. several extra products" do
    it "are all accepted — the full example from the brief (شامبو، ماسك، كريم، زيت)" do
      receipt = create_receipt(request_line(pri_shampoo, 10, 20), request_line(pri_mask, 5, 30),
                               extra_line(cream, 3, 15), extra_line(oil, 2, 12.5))

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.items.count).to eq(4)
      expect(receipt.items.where(purchase_request_item_id: nil).pluck(:product_id)).to contain_exactly(cream.id, oil.id)
    end

    it "a receipt may even hold only extra products while still referencing the request" do
      receipt = create_receipt(extra_line(cream, 3, 15))
      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.purchase_request).to eq(pr)
    end
  end

  describe "D. receipts without a Purchase Request" do
    it "work exactly as before" do
      receipt = create_receipt(extra_line(cream, 3, 15), extra_line(oil, 2, 12.5), purchase_request: nil)

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.purchase_request).to be_nil
      expect(receipt.total_value).to eq(70)
    end
  end

  describe "E. the Purchase Request is never changed by extras" do
    it "keeps its lines, quantities and status through create, approve and receive" do
      before_snapshot = pr_snapshot
      receipt = create_receipt(request_line(pri_shampoo, 4, 20), extra_line(cream, 3, 15), extra_line(oil, 2, 12.5))
      expect(pr_snapshot).to eq(before_snapshot)

      expect(Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: owner).submit!).to be_ok
      expect(Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: owner).approve!).to be_ok
      expect(Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: owner).call).to be_ok

      pr.reload
      expect(pr.items.count).to eq(2)
      expect(pr.items.pluck(:product_id)).to contain_exactly(shampoo.id, mask.id)
      # Only the request's own line counts toward the request.
      expect(pri_shampoo.reload.received_quantity).to eq(4)
      expect(pri_mask.reload.received_quantity).to eq(0)
      expect(pr).to be_partially_received
    end
  end

  describe "F. the receipt total includes every line" do
    it "sums request lines and extras the same way (quantity × unit cost)" do
      receipt = create_receipt(request_line(pri_shampoo, 10, 20), request_line(pri_mask, 5, 30),
                               extra_line(cream, 3, 15), extra_line(oil, 2, 12.5))

      # 10×20 + 5×30 + 3×15 + 2×12.5 = 200 + 150 + 45 + 25
      expect(receipt.total_value).to eq(420)
      expect(receipt.items.find_by(product: oil).total_cost).to eq(25)
    end
  end

  describe "G. approval and receiving are unchanged" do
    it "approves and receives a receipt with extras, posting stock for every line" do
      receipt = create_receipt(request_line(pri_shampoo, 10, 20), request_line(pri_mask, 5, 30),
                               extra_line(cream, 3, 15))

      expect(receipt).to be_approval_draft
      expect(Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: owner).submit!).to be_ok
      expect(Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: owner).approve!).to be_ok
      expect(Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: owner).call).to be_ok

      expect(receipt.reload).to be_confirmed
      expect(shampoo.reload.current_stock).to eq(10)
      expect(mask.reload.current_stock).to eq(5)
      expect(cream.reload.current_stock).to eq(3)
      expect(pr.reload).to be_fully_received
    end
  end

  describe "guards that still hold" do
    it "a request product added as an unreferenced 'extra' line is refused (can't bypass the remaining-quantity guard)" do
      expect do
        create_receipt(extra_line(shampoo, 999, 20))
      end.not_to change(GoodsReceipt, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("activerecord.errors.models.goods_receipt_item.attributes.product_id.on_purchase_request", locale: :ar))
      expect(response.body).not_to include("يجب أن يشير إلى صنف من طلب الشراء المرتبط")
    end

    it "a request line still can't exceed its remaining quantity" do
      expect { create_receipt(request_line(pri_mask, 6, 30)) }.not_to change(GoodsReceipt, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "a reference to another request's line is refused" do
      other = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
      other.items.build(product: cream, quantity: 1, unit_price: 15, source_warehouse: warehouse)
      other.save!

      expect { create_receipt(request_line(other.items.first, 1, 15)) }.not_to change(GoodsReceipt, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "an invalid quantity on an extra line is still refused" do
      expect { create_receipt(extra_line(cream, 0, 15)) }.not_to change(GoodsReceipt, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "new receipt form from a Purchase Request (Arabic)" do
    def form_doc
      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)
      Nokogiri::HTML(response.body)
    end

    it "shows منتجات طلب الشراء with requested/received/remaining, then منتجات إضافية and + إضافة منتج" do
      doc = form_doc
      headings = doc.css("tr.line-items-section th").map { |th| th.text.squish }
      expect(headings.first).to start_with("منتجات طلب الشراء").and include(pr.request_number)
      expect(headings.last).to start_with("منتجات إضافية")

      request_rows = doc.css("tr.line-items-row--request")
      expect(request_rows.size).to eq(2)
      # Each request line's product is fixed to that line's product.
      expect(request_rows.map { |r| r.css("select option").map { |o| o["value"].to_i } })
        .to contain_exactly([ shampoo.id ], [ mask.id ])
      expect(request_rows.map(&:text).join).to include("المطلوب 10 · المستلم 0 · المتبقي 10")

      expect(doc.at_css("button[data-action='line-items#add']").text.squish).to eq("+ إضافة منتج")
      # New rows offer the whole catalog and are marked as outside the request.
      template = Nokogiri::HTML(doc.at_css("template[data-line-items-target='template']").inner_html)
      expect(template.css("select option").map { |o| o["value"] }.compact_blank.map(&:to_i))
        .to include(shampoo.id, mask.id, cream.id, oil.id)
      expect(template.text).to include("خارج طلب الشراء")
    end

    it "a receipt without a request keeps the single items table and its add button" do
      get new_inventory_goods_receipt_path
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("tr.line-items-section")).to be_empty
      expect(doc.at_css("button[data-action='line-items#add']").text.squish)
        .to eq("+ #{I18n.t('inventory.goods_receipts.add_item', locale: :ar)}")
    end
  end
end
