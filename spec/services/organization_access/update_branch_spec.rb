require "rails_helper"

# Warehouse Architecture — PR 3: only a non-sales -> sales change provisions
# the branch warehouse (atomically); every other update leaves warehouses alone.
RSpec.describe OrganizationAccess::UpdateBranch do
  let(:business) { create(:business) }
  let(:admin)    { user_with_stock_permissions(business, :manage_branches) }
  let(:product)  { business.products.create!(name: "Shampoo", sku: "SH-#{SecureRandom.hex(2)}", average_cost_price: 5) }

  def update(branch, actor: admin, rows: nil, **attributes)
    described_class.new(branch.id, actor: actor, attributes: attributes.transform_keys(&:to_s), terminal_rows: rows).call
  end

  def warehouse_audits = AuditLog.where(auditable_type: "Warehouse", action: "create")

  describe "non-sales -> sales" do
    let(:laundry) { create(:branch, business: business, name: "Wash", branch_type: "laundry") }

    it "provisions exactly one branch warehouse in the same change" do
      result = update(laundry, branch_type: "sales")

      expect(result).to be_ok
      expect(laundry.reload).to be_branch_type_sales
      warehouse = Warehouse.find_by!(branch_id: laundry.id)
      expect(warehouse).to have_attributes(kind: "branch", name: "Wash – المخزن", business_id: business.id)
      expect(warehouse_audits.sole.metadata).to include("source" => "branch_provisioning", "branch_id" => laundry.id)
    end

    it "uses the branch name submitted in the same update" do
      update(laundry, branch_type: "sales", name: "New Wash")

      expect(Warehouse.find_by!(branch_id: laundry.id).name).to eq("New Wash – المخزن")
    end

    it "rolls the whole update back when provisioning fails (name already taken)" do
      business.warehouses.create!(name: "Wash – المخزن", kind: "central")

      result = update(laundry, branch_type: "sales", address: "Changed")

      expect(result).not_to be_ok
      expect(result.error).to eq(:warehouse_provisioning_failed)
      expect(result.record.errors[:base].sole)
        .to include(I18n.t("inventory.warehouses.errors.name_taken", name: "Wash – المخزن"))
      expect(laundry.reload).to have_attributes(branch_type: "laundry", address: laundry.address)
      expect(Warehouse.where(branch_id: laundry.id)).to be_empty
      expect(warehouse_audits).to be_empty
    end

    it "never duplicates on repeated changes: back to laundry and to sales again keeps the one warehouse, unaudited" do
      expect(update(laundry, branch_type: "sales")).to be_ok
      warehouse = Warehouse.find_by!(branch_id: laundry.id)

      expect(update(laundry, branch_type: "laundry")).to be_ok
      expect(update(laundry, branch_type: "sales")).to be_ok
      expect(update(laundry, branch_type: "sales", name: "Wash 2")).to be_ok

      expect(Warehouse.where(branch_id: laundry.id).pluck(:id)).to eq([ warehouse.id ])
      expect(warehouse.reload).to have_attributes(name: "Wash – المخزن", kind: "branch")
      expect(warehouse_audits.count).to eq(1)
    end
  end

  describe "sales -> non-sales" do
    let(:sales) { create(:branch, business: business, name: "Nasr", branch_type: "sales") }
    let!(:warehouse) do
      # Provisioned through the only branch-warehouse creation path.
      Warehouse.transaction do
        Inventory::WarehouseManager.new(actor: user_with_stock_permissions(business, :manage_branches))
                                   .provision_branch_warehouse(branch: sales).warehouse
      end
    end

    it "keeps the warehouse, its stock and its movements exactly as they were" do
      InventoryMovement.create!(business: business, product: product, warehouse: warehouse, direction: :in,
                                reason: :opening_balance, quantity: 7, unit_cost: 5, occurred_on: Date.new(2026, 1, 1))
      before = InventoryMovement.where(warehouse_id: warehouse.id).pluck(:id, :quantity, :direction, :reason)

      expect { expect(update(sales, branch_type: "laundry")).to be_ok }.not_to change(AuditLog.where(auditable_type: "Warehouse"), :count)

      expect(warehouse.reload).to have_attributes(kind: "branch", branch_id: sales.id, name: "Nasr – المخزن", status: "active")
      expect(InventoryMovement.where(warehouse_id: warehouse.id).pluck(:id, :quantity, :direction, :reason)).to eq(before)
      expect(product.stock_in(warehouse)).to eq(7)
    end
  end

  describe "updates that are not a change to sales" do
    it "a rename of an existing sales branch without a warehouse provisions nothing (left to the backfill)" do
      sales = create(:branch, business: business, branch_type: "sales")

      expect(update(sales, name: "Renamed")).to be_ok
      expect(Warehouse.count).to eq(0)
    end

    it "an edit of a non-sales branch provisions nothing" do
      hq = create(:branch, business: business, branch_type: "headquarters")

      expect(update(hq, name: "HQ 2", branch_type: "maintenance")).to be_ok
      expect(Warehouse.count).to eq(0)
    end

    it "a rename never renames or touches the existing branch warehouse" do
      laundry = create(:branch, business: business, name: "Wash", branch_type: "laundry")
      update(laundry, branch_type: "sales")

      expect(update(laundry, name: "Wash Renamed")).to be_ok
      expect(Warehouse.find_by!(branch_id: laundry.id).name).to eq("Wash – المخزن")
    end
  end

  it "refuses an unknown branch type as a form error and changes nothing" do
    laundry = create(:branch, business: business, branch_type: "laundry")
    result = update(laundry, branch_type: "casino")

    expect(result.record.errors.of_kind?(:branch_type, :inclusion)).to be(true)
    expect(laundry.reload).to be_branch_type_laundry
    expect(Warehouse.count).to eq(0)
  end

  it "refuses an actor without manage_branches" do
    laundry = create(:branch, business: business, branch_type: "laundry")
    result = update(laundry, actor: user_with_stock_permissions(business, :view_inventory), branch_type: "sales")

    expect(result.error).to eq(:not_authorized)
    expect(laundry.reload).to be_branch_type_laundry
    expect(Warehouse.count).to eq(0)
  end

  it "cannot reach another business's branch" do
    foreign = create(:branch, branch_type: "laundry")

    expect { update(foreign, branch_type: "sales") }.to raise_error(ActiveRecord::RecordNotFound)
    expect(foreign.reload).to be_branch_type_laundry
  end
end
