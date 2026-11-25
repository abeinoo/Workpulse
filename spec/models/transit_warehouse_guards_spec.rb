require "rails_helper"

# Stock Transfer redesign, Phase A: the system transit warehouse exists only
# for transfer legs. Every document, assignment, setting and supply link is
# refused at the model level AND, independently, by the database
# (*_operational_warehouse_only triggers) — a write that skips validations is
# still refused. Movements pair transit reasons with the transit warehouse.
RSpec.describe "System transit warehouse guards" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:main)    { business.warehouses.create!(name: "Main", kind: "central") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5) }
  let(:transit)  { Inventory::TransitWarehouse.for!(business, actor: owner) }

  def db_refuses(&block)
    expect { ActiveRecord::Base.transaction(requires_new: true, &block) }
      .to raise_error(ActiveRecord::StatementInvalid, /cannot reference the system transit warehouse|transit/)
  end

  describe Warehouse do
    it "is a transit-kind, active, branchless row with a reserved name, shown by its translated name" do
      expect(transit).to be_transit
      expect(transit).to be_active
      expect(transit.branch_id).to be_nil
      expect(transit.name).to eq(Warehouse::TRANSIT_NAME)
      expect(transit.display_name).to eq(I18n.t("inventory.transit_warehouse.name"))
      expect(I18n.with_locale(:ar) { transit.display_name }).to eq("بالطريق")
    end

    it "is never created through an ordinary save" do
      w = business.warehouses.build(name: Warehouse::TRANSIT_NAME, kind: "transit")
      expect(w).not_to be_valid
      expect(w.errors[:kind]).to be_present
    end

    it "reserves the transit name for the transit warehouse" do
      w = business.warehouses.build(name: Warehouse::TRANSIT_NAME.upcase, kind: "central")
      expect(w).not_to be_valid
      expect(w.errors[:name]).to be_present
    end

    it "never changes and is never destroyed" do
      expect(transit.update(name: "Renamed")).to be(false)
      expect(transit.reload.update(description: "x")).to be(false)
      expect(transit.reload.destroy).to be(false)
      expect(Warehouse.transit.where(business: business).count).to eq(1)
    end

    it "is left out of .operational" do
      transit
      expect(business.warehouses.operational).to contain_exactly(main)
      expect(business.warehouses.transit).to eq([ transit ])
    end

    it "is refused by the database when inactive or duplicated" do
      transit
      expect { ActiveRecord::Base.transaction(requires_new: true) { transit.update_columns(status: "inactive") } }
        .to raise_error(ActiveRecord::StatementInvalid, /warehouses_transit_always_active/)
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          Warehouse.insert_all!([ { business_id: business.id, name: "dup", kind: "transit", status: "active",
                                    created_at: Time.current, updated_at: Time.current } ])
        end
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "documents, assignments and settings" do
    def refused(record, attribute)
      expect(record).not_to be_valid
      expect(record.errors[attribute]).to include(I18n.t("activerecord.errors.messages.transit_warehouse"))
    end

    it "refuses them at the model level" do
      refused(business.stock_issues.build(warehouse: transit, issued_on: Date.current), :warehouse_id)
      refused(business.stock_adjustments.build(warehouse: transit, adjusted_on: Date.current, reason: "damaged"), :warehouse_id)
      refused(business.stock_counts.build(warehouse: transit, counted_on: Date.current), :warehouse_id)
      refused(business.goods_receipts.build(warehouse: transit, received_on: Date.current), :warehouse_id)
      refused(business.purchase_requests.build(warehouse: transit), :warehouse_id)
      refused(PurchaseRequestItem.new(source_warehouse: transit), :source_warehouse_id)
      refused(business.stock_transfers.build(source_warehouse: transit, destination_warehouse: main), :source_warehouse_id)
      refused(business.stock_transfers.build(source_warehouse: main, destination_warehouse: transit), :destination_warehouse_id)
      refused(WarehouseAssignment.new(user: owner, warehouse: transit), :warehouse_id)
      refused(WarehouseBranchSupply.new(warehouse: transit), :warehouse_id)
      refused(ProductWarehouseSetting.new(product: product, warehouse: transit), :warehouse_id)
      refused(StockIssueImportBatch.new(business: business, warehouse: transit), :warehouse_id)
    end

    it "refuses them in the database even when validations are skipped" do
      transit # created before any refused write's savepoint rolls back
      sql = ActiveRecord::Base.connection
      db_refuses do
        sql.execute("INSERT INTO warehouse_assignments (user_id, warehouse_id, created_at, updated_at) " \
                    "VALUES (#{owner.id}, #{transit.id}, now(), now())")
      end
      db_refuses do
        sql.execute("INSERT INTO product_warehouse_settings (product_id, warehouse_id, business_id, created_at, updated_at) " \
                    "VALUES (#{product.id}, #{transit.id}, #{business.id}, now(), now())")
      end
      issue = business.stock_issues.build(warehouse: main, issued_on: Date.current).tap { |i| i.save!(validate: false) }
      db_refuses { issue.update_column(:warehouse_id, transit.id) }
      transfer = business.stock_transfers.build(source_warehouse: main, destination_warehouse: business.warehouses.create!(name: "Annex"),
                                                transfer_number: "TRF-X", transferred_on: Date.current)
      transfer.save!(validate: false)
      db_refuses { transfer.update_column(:destination_warehouse_id, transit.id) }
    end
  end

  describe InventoryMovement do
    def movement(warehouse, reason, direction)
      InventoryMovement.new(business: business, product: product, warehouse: warehouse, reason: reason, direction: direction,
                            quantity: 1, unit_cost: 5, occurred_on: Date.current)
    end

    it "takes only transit legs in the transit warehouse, and transit legs only there" do
      expect(movement(transit, "transit_in", "in")).to be_valid
      expect(movement(transit, "transit_out", "out")).to be_valid
      expect(movement(transit, "transfer_loss", "out")).to be_valid
      expect(movement(transit, "opening_balance", "in")).not_to be_valid
      expect(movement(transit, "stock_issue", "out")).not_to be_valid
      expect(movement(main, "transit_in", "in")).not_to be_valid
      expect(movement(main, "transfer_return", "in")).to be_valid
    end

    it "fixes each transit-workflow reason's direction" do
      expect(movement(transit, "transit_in", "out")).not_to be_valid
      expect(movement(transit, "transfer_loss", "in")).not_to be_valid
      expect(movement(main, "transfer_return", "out")).not_to be_valid
    end

    it "is enforced by the database too" do
      expect { movement(transit, "opening_balance", "in").save!(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /transit warehouse takes only transit legs/)
      expect { movement(main, "transit_in", "in").save!(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /transit warehouse takes only transit legs/)
    end

    it "keeps the business total including transit stock (moving-average basis)" do
      InventoryMovement.create!(business: business, product: product, warehouse: main, reason: "opening_balance", direction: "in",
                                quantity: 10, unit_cost: 5, occurred_on: Date.current)
      movement(main, "transfer_out", "out").tap { |m| m.quantity = 4 }.save!
      movement(transit, "transit_in", "in").tap { |m| m.quantity = 4 }.save!
      expect(product.current_stock).to eq(10)
      expect(product.stock_in(main)).to eq(6)
      expect(product.stock_in(transit)).to eq(4)
    end
  end
end
