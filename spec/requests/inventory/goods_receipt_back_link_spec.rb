require "rails_helper"

# The new Goods Receipt form's Back link returns to where the user came from:
# the Purchase Request it was opened from (also after a failed save), otherwise
# the Goods Receipts list. The request comes from the controller's
# policy-scoped lookup — never from a user-supplied URL.
RSpec.describe "New Goods Receipt — Back link", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }

  let(:request_record) do
    pr = business.purchase_requests.build(supplier: supplier, created_by: owner)
    pr.items.build(product: product, quantity: 5, unit_price: 100, source_warehouse: warehouse)
    pr.save!
    pr.update_columns(status: "pending_approval", submitted_by_id: owner.id)
    Inventory::PurchaseRequestApproval.new(purchase_request_id: pr.id, actor: owner).approve!
    pr.reload
  end

  def back_link
    link = Nokogiri::HTML(response.body).at_css("[data-testid='goods-receipt-back-link']")
    [ link["href"], link.text.strip ]
  end

  def cancel_link
    Nokogiri::HTML(response.body).at_css("[data-testid='gr-form-actions'] a")["href"]
  end

  before { sign_in owner }

  %w[en ar].each do |locale|
    context "in #{locale}" do
      before { owner.update!(preferred_locale: locale) }

      it "opened from a Purchase Request: Back returns to that request" do
        get new_inventory_goods_receipt_path(purchase_request_id: request_record.id)

        expect(response).to have_http_status(:ok)
        expect(back_link).to eq([ inventory_purchase_request_path(request_record), I18n.t("forms.back", locale: locale) ])
        expect(cancel_link).to eq(inventory_purchase_request_path(request_record))
      end

      it "opened from the Goods Receipts list: Back returns to the list" do
        get new_inventory_goods_receipt_path

        expect(response).to have_http_status(:ok)
        expect(back_link).to eq([ inventory_goods_receipts_path, I18n.t("forms.back", locale: locale) ])
        expect(cancel_link).to eq(inventory_goods_receipts_path)
      end
    end
  end

  it "after a failed save of a receipt from a Purchase Request, Back still returns to that request" do
    expect {
      post inventory_goods_receipts_path, params: {
        goods_receipt: { purchase_request_id: request_record.id, supplier_id: supplier.id, warehouse_id: warehouse.id,
                         received_on: "", funding_source_kind: "supplier_credit" }
      }
    }.not_to change(GoodsReceipt, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(back_link.first).to eq(inventory_purchase_request_path(request_record))
    expect(cancel_link).to eq(inventory_purchase_request_path(request_record))
    expect(response.body).to include(%(value="#{request_record.id}")) # purchase_request_id kept in the form
  end

  it "after a failed save of a standalone receipt, Back returns to the list" do
    post inventory_goods_receipts_path, params: {
      goods_receipt: { supplier_id: supplier.id, warehouse_id: warehouse.id, received_on: "" }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(back_link.first).to eq(inventory_goods_receipts_path)
  end

  it "never links to another business's Purchase Request named in the submitted form" do
    other = create(:business)
    foreign = other.purchase_requests.build(supplier: other.suppliers.create!(name: "X"))
    foreign.items.build(product: other.products.create!(name: "P", sku: "P-1"), quantity: 1, unit_price: 5)
    foreign.save!

    post inventory_goods_receipts_path, params: {
      goods_receipt: { purchase_request_id: foreign.id, supplier_id: supplier.id, warehouse_id: warehouse.id, received_on: "" }
    }

    expect(back_link.first).to eq(inventory_goods_receipts_path)
    expect(response.body).not_to include(inventory_purchase_request_path(foreign))
  end

  it "editing a receipt keeps its own navigation: Back to the receipt, Cancel to the list" do
    receipt = business.goods_receipts.build(purchase_request: request_record, supplier: supplier, warehouse: warehouse,
                                            received_on: Date.current, funding_source_kind: "supplier_credit")
    receipt.items.build(product: product, quantity: 1, unit_cost: 100, purchase_request_item: request_record.items.first)
    receipt.save!

    get edit_inventory_goods_receipt_path(receipt)

    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css("a.back-link")["href"]).to eq(inventory_goods_receipt_path(receipt))
    expect(cancel_link).to eq(inventory_goods_receipts_path)
  end
end
