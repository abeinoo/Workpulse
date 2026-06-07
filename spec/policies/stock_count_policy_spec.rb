require "rails_helper"

RSpec.describe StockCountPolicy do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer)  { user_with("view_inventory") }
  let(:counter) { user_with("view_inventory", "manage_stock_counts") }
  let(:poster)  { user_with("view_inventory", "post_stock_counts") }

  let(:draft)  { business.stock_counts.create!(warehouse: warehouse, counted_on: Date.current, count_number: "SC-1", items_attributes: { "0" => { product_id: product.id, counted_quantity: 1 } }) }
  let(:product) { business.products.create!(name: "P", sku: "P-1", initial_cost_price: 1, average_cost_price: 1) }

  it "lets viewers see but not create" do
    expect(StockCountPolicy.new(viewer, StockCount).index?).to be(true)
    expect(StockCountPolicy.new(viewer, StockCount).create?).to be(false)
    expect(StockCountPolicy.new(viewer, draft).post?).to be(false)
  end

  it "lets a counter create/edit drafts but not post" do
    expect(StockCountPolicy.new(counter, StockCount).create?).to be(true)
    expect(StockCountPolicy.new(counter, draft).update?).to be(true)
    expect(StockCountPolicy.new(counter, draft).post?).to be(false)
  end

  it "lets a poster post but not create" do
    expect(StockCountPolicy.new(poster, draft).post?).to be(true)
    expect(StockCountPolicy.new(poster, StockCount).create?).to be(false)
  end

  it "blocks update/post on an already-posted count" do
    draft.update_columns(status: "posted", posted_at: Time.current)
    expect(StockCountPolicy.new(counter, draft.reload).update?).to be(false)
    expect(StockCountPolicy.new(poster, draft.reload).post?).to be(false)
  end
end
