require "rails_helper"

RSpec.describe StockCountPolicy do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "P", sku: "P-1", initial_cost_price: 1, average_cost_price: 1) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer)   { user_with("view_inventory") }
  let(:counter)  { user_with("view_inventory", "manage_stock_counts") }
  let(:approver) { user_with("view_inventory", "post_stock_counts") }

  # A session at a given status (count_number assigned on create).
  def count_at(status)
    c = business.stock_counts.create!(warehouse: warehouse, counted_on: Date.current,
                                      items_attributes: { "0" => { product_id: product.id, counted_quantity: 1 } })
    c.update_column(:status, status.to_s)
    c.reload
  end

  it "lets viewers see but not create or approve" do
    expect(StockCountPolicy.new(viewer, StockCount).index?).to be(true)
    expect(StockCountPolicy.new(viewer, StockCount).create?).to be(false)
    expect(StockCountPolicy.new(viewer, count_at(:completed)).approve?).to be(false)
  end

  it "lets a counter create, edit while in progress, and complete — but not approve" do
    expect(StockCountPolicy.new(counter, StockCount).create?).to be(true)
    expect(StockCountPolicy.new(counter, count_at(:in_progress)).update?).to be(true)
    expect(StockCountPolicy.new(counter, count_at(:in_progress)).complete?).to be(true)
    expect(StockCountPolicy.new(counter, count_at(:completed)).approve?).to be(false)
  end

  it "lets an approver approve a completed count but not create" do
    expect(StockCountPolicy.new(approver, count_at(:completed)).approve?).to be(true)
    expect(StockCountPolicy.new(approver, count_at(:completed)).reopen?).to be(true)
    expect(StockCountPolicy.new(approver, StockCount).create?).to be(false)
  end

  it "blocks editing and approval once approved" do
    approved = count_at(:approved)
    expect(StockCountPolicy.new(counter, approved).update?).to be(false)
    expect(StockCountPolicy.new(approver, approved).approve?).to be(false)
  end

  # Segregation of duties: an approver may not approve a count they ran or
  # submitted themselves — another authorized approver must.
  it "blocks an approver from approving a count they created (no self-approval)" do
    own = count_at(:completed)
    own.update_column(:created_by_id, approver.id)
    expect(StockCountPolicy.new(approver, own.reload).approve?).to be(false)
  end

  it "blocks an approver from approving a count they submitted (no self-approval)" do
    own = count_at(:completed)
    own.update_column(:completed_by_id, approver.id)
    expect(StockCountPolicy.new(approver, own.reload).approve?).to be(false)
  end

  it "still lets a different approver approve a count submitted by someone else" do
    count = count_at(:completed)
    count.update_column(:completed_by_id, counter.id)
    expect(StockCountPolicy.new(approver, count.reload).approve?).to be(true)
  end
end
