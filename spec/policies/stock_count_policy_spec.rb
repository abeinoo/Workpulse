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

  # Decision D1: the business owner is the one self-approval exception.
  it "lets the business owner approve their own count, flagged as the exception" do
    owner = create(:user, :owner, business: business)
    own = count_at(:completed)
    own.update_columns(created_by_id: owner.id, completed_by_id: owner.id)
    policy = StockCountPolicy.new(owner, own.reload)
    expect(policy.approve?).to be(true)
    expect(policy.owner_self_approval?).to be(true)
    expect(StockCountPolicy.new(owner, count_at(:completed)).owner_self_approval?).to be(false)
  end

  it "does not grant the exception to an ordinary approver" do
    own = count_at(:completed)
    own.update_column(:created_by_id, approver.id)
    expect(StockCountPolicy.new(approver, own.reload).owner_self_approval?).to be(false)
    expect(StockCountPolicy.new(approver, own).approve?).to be(false)
  end

  it "lets an approver (not a counter) reopen a completed or approved count, nothing else" do
    expect(StockCountPolicy.new(approver, count_at(:approved)).reopen?).to be(true)
    expect(StockCountPolicy.new(counter, count_at(:approved)).reopen?).to be(false)
    %i[draft in_progress cancelled].each do |status|
      expect(StockCountPolicy.new(approver, count_at(status)).reopen?).to be(false)
    end
  end

  describe "delete vs cancel (D4)" do
    def posted(count)
      adjustment = StockAdjustment.new(business: business, warehouse: warehouse, stock_count: count,
                                       adjusted_on: Date.current, reason: "stock_count", adjustment_number: "ADJ-#{SecureRandom.hex(3)}",
                                       voided_at: Time.current, void_reason: "reopened")
      adjustment.save!(validate: false)
      count.reload
    end

    it "deletes only a never-posted draft or in-progress count" do
      expect(StockCountPolicy.new(counter, count_at(:draft)).destroy?).to be(true)
      expect(StockCountPolicy.new(counter, count_at(:in_progress)).destroy?).to be(true)
      %i[completed approved cancelled].each do |status|
        expect(StockCountPolicy.new(counter, count_at(status)).destroy?).to be(false)
      end
      expect(StockCountPolicy.new(counter, posted(count_at(:in_progress))).destroy?).to be(false)
      expect(StockCountPolicy.new(viewer, count_at(:draft)).destroy?).to be(false)
    end

    it "cancels only a reopened count that once posted stock" do
      expect(StockCountPolicy.new(counter, posted(count_at(:in_progress))).cancel?).to be(true)
      expect(StockCountPolicy.new(counter, count_at(:in_progress)).cancel?).to be(false)
      expect(StockCountPolicy.new(viewer, posted(count_at(:in_progress))).cancel?).to be(false)
    end
  end
end
