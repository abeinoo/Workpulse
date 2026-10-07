require "rails_helper"

# SEC-P6-6 (found in Pilot 6 — Inventory & Purchasing Supplier, M1; High): a
# product's parent_product_id accepted another business's product. Saving it
# ran Product#propagate_non_tracking_to_parent (after_save) →
# force_non_tracking! on the FOREIGN product, switching off its
# track_inventory and receive_low_stock_notification — a write into another
# business — and listed the attacker's product among its children.
#
# Product now validates that its parent belongs to the product's business. A
# validation failure aborts the save before any save callback runs, so neither
# the attacker's product nor the victim's product is written.
RSpec.describe "Security: parent product business isolation", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :view_inventory, :manage_inventory) }
  let!(:own_parent)     { business.products.create!(name: "Own Parent", sku: "OP-1", initial_cost_price: 1, average_cost_price: 1) }
  let!(:foreign_parent) { other.products.create!(name: "Foreign Parent", sku: "FP-1", initial_cost_price: 1, average_cost_price: 1) }

  # Every column of the victim's product, timestamps included.
  def victim_snapshot = foreign_parent.reload.attributes

  before { sign_in manager }

  it "refuses creating a child of another business's product, writing nothing to either side" do
    before_attack = victim_snapshot
    expect(foreign_parent.track_inventory).to be(true)

    expect do
      post inventory_products_path,
           params: { product: { name: "Child", sku: "C-1", initial_cost_price: 1, parent_product_id: foreign_parent.id } }
    end.not_to change(Product, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(victim_snapshot).to eq(before_attack)
    expect(foreign_parent.child_products).to be_empty
  end

  it "refuses re-parenting an existing product under another business's product, writing nothing to either side" do
    product = business.products.create!(name: "Child", sku: "C-2", initial_cost_price: 1, average_cost_price: 1)
    own_before    = product.reload.attributes
    before_attack = victim_snapshot

    patch inventory_product_path(product), params: { product: { parent_product_id: foreign_parent.id } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(product.reload.attributes).to eq(own_before)
    expect(victim_snapshot).to eq(before_attack)
    expect(foreign_parent.child_products).to be_empty
  end

  it "still links a same-business parent and switches off its tracking, as before" do
    post inventory_products_path,
         params: { product: { name: "Child", sku: "C-3", initial_cost_price: 1, parent_product_id: own_parent.id } }

    expect(business.products.find_by!(sku: "C-3").parent_product).to eq(own_parent)
    expect(own_parent.reload).to have_attributes(track_inventory: false, receive_low_stock_notification: false)
  end

  it "still allows no parent" do
    post inventory_products_path, params: { product: { name: "Root", sku: "R-1", initial_cost_price: 1, parent_product_id: "" } }
    expect(business.products.find_by!(sku: "R-1").parent_product).to be_nil
  end

  it "the model refuses a foreign parent on every write path, before any callback can write it" do
    before_attack = victim_snapshot
    product = business.products.build(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1,
                                      parent_product: foreign_parent)

    expect(product.save).to be(false)
    expect(product.errors[:parent_product]).to be_present
    expect(victim_snapshot).to eq(before_attack)
  end
end
