require "rails_helper"

RSpec.describe "Goods receipt funding source", type: :request do
  let(:business)  { create(:business) }
  let(:manager)   { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0) }
  let!(:my_account)     { create(:custody_account, business: business, user: manager, current_balance: 1000) }
  let!(:other_account)  { create(:custody_account, business: business, current_balance: 5000) }

  before { sign_in manager }

  def create_receipt(funding_source_kind:, funding_source_id: nil)
    post inventory_goods_receipts_path, params: {
      goods_receipt: {
        warehouse_id: warehouse.id, received_on: Date.current, funding_source_kind: funding_source_kind,
        items_attributes: { "0" => { product_id: product.id, quantity: 1, unit_cost: 10 } }
      },
      funding_source_id: funding_source_id
    }.compact
    business.goods_receipts.order(:created_at).last
  end

  it "auto-assigns the acting user's own custody account, ignoring any funding_source_id param" do
    receipt = create_receipt(funding_source_kind: "employee_custody", funding_source_id: other_account.id)

    expect(receipt.funding_source).to eq(my_account)
    expect(receipt.funding_source).not_to eq(other_account)
  end

  it "leaves funding_source blank for non-custody kinds" do
    receipt = create_receipt(funding_source_kind: "company_cash")
    expect(receipt.funding_source).to be_nil
  end

  it "no longer offers Branch Cash as a funding source kind" do
    expect(GoodsReceipt::FUNDING_SOURCE_KINDS).not_to include("branch_cash")
  end

  describe "employee custody panel markup on the new-receipt form" do
    def radio_inputs(body)
      body.scan(/<input [^>]*name="goods_receipt\[funding_source_kind\]"[^>]*\/>/)
    end

    def checked_value(body)
      radio_inputs(body).select { |tag| tag.include?("checked=\"checked\"") }
                        .map { |tag| tag[/value="([^"]+)"/, 1] }
    end

    it "marks exactly one radio checked (employee_custody) and shows the panel by default" do
      get new_inventory_goods_receipt_path

      expect(checked_value(response.body)).to eq([ "employee_custody" ])
      expect(response.body).to include(I18n.t("inventory.goods_receipts.my_balance"))
      expect(response.body).not_to match(/data-funding-source-target="panel" class="form-group hidden"/)
    end

    it "hides the panel server-side when re-rendering a failed submission with a non-custody kind" do
      post inventory_goods_receipts_path, params: {
        goods_receipt: { warehouse_id: warehouse.id, received_on: Date.current, funding_source_kind: "company_cash", items_attributes: {} }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(checked_value(response.body)).to eq([ "company_cash" ])
      expect(response.body).to match(/data-funding-source-target="panel" class="form-group hidden"/)
    end
  end
end
