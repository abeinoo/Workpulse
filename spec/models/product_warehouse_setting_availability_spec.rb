require "rails_helper"

# Product availability per warehouse — Phase 1, unit 1: the availability state
# of a product_warehouse_settings row and its database guarantees.
RSpec.describe ProductWarehouseSetting, "availability state" do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:central) { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:shubra_branch) { create(:branch, business: business, name: "Shoubra", branch_type: "sales") }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1,
                              low_stock_level: 10, reorder_level: 10, reorder_quantity: 20, receive_low_stock_notification: true)
  end

  def configure(warehouse = central, **attrs)
    product.product_warehouse_settings.create!({ warehouse: warehouse, low_stock_level: 3, reorder_quantity: 10 }.merge(attrs))
  end

  it "a new row is Active with per-warehouse notifications on and the product's business" do
    row = configure
    expect(row).to be_status_active
    expect(row.receive_low_stock_notification).to be(true)
    expect(row.business_id).to eq(business.id)
  end

  it "an Inactive row requires a reason (model) and keeps its settings" do
    row = configure(low_stock_level: 7, reorder_quantity: 14)
    row.status = "inactive"
    expect(row).not_to be_valid
    expect(row.errors[:status_reason]).to be_present

    row.update!(status_reason: "no longer used here", status_changed_at: Time.current)
    expect(row.reload).to be_status_inactive
    expect([ row.low_stock_level, row.reorder_quantity ]).to eq([ 7, 14 ])
  end

  it "rejects an unknown status" do
    expect { configure(status: "archived") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects a business other than the product's" do
    row = product.product_warehouse_settings.build(warehouse: central, low_stock_level: 1, reorder_quantity: 1, business: other)
    expect(row).not_to be_valid
    expect(row.errors[:business_id]).to be_present
  end

  describe "database constraints (bypassing validations)" do
    let!(:row) { configure }

    it "refuses an unknown status" do
      expect { row.update_columns(status: "archived", status_reason: "x", status_changed_at: Time.current) }.to raise_error(ActiveRecord::StatementInvalid, /pws_status_known/)
    end

    it "refuses an inactive row without a reason and change time" do
      expect { row.update_column(:status, "inactive") }.to raise_error(ActiveRecord::StatementInvalid, /pws_inactive_has_reason/)
    end

    it "refuses a negative threshold" do
      expect { row.update_column(:low_stock_level, -1) }.to raise_error(ActiveRecord::StatementInvalid, /pws_quantities_non_negative/)
    end

    it "refuses a negative reorder quantity" do
      expect { row.update_column(:reorder_quantity, -1) }.to raise_error(ActiveRecord::StatementInvalid, /pws_quantities_non_negative/)
    end

    it "refuses a missing business" do
      expect { row.update_column(:business_id, nil) }.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "keeps one row per product and warehouse" do
      expect {
        ProductWarehouseSetting.insert_all!([ { product_id: product.id, warehouse_id: central.id, business_id: business.id,
                                                 low_stock_level: 1, reorder_quantity: 1, created_at: Time.current, updated_at: Time.current } ])
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "Not Configured is the absence of a row" do
    it "creating a product configures no warehouse" do
      expect { product }.not_to change(ProductWarehouseSetting, :count)
    end

    it "provisioning a branch warehouse configures no product there, and the product's legacy values are not copied" do
      product
      branch_wh = Inventory::WarehouseManager.new(actor: create(:user, :owner, business: business))
                                             .provision_branch_warehouse(branch: shubra_branch).warehouse
      expect(branch_wh).to be_persisted
      expect(ProductWarehouseSetting.where(warehouse_id: branch_wh.id)).to be_empty
      expect(product.reload.product_warehouse_settings).to be_empty
    end
  end
end
