require "rails_helper"

# Stock Transfer redesign, Phase A — leakage audit. With the business's system
# transit warehouse provisioned, an OWNER (who reaches "every warehouse") must
# never see it as a warehouse: not in any picker, list, report filter, access
# form or warehouse page, and no service accepts it from a caller-supplied id.
RSpec.describe "System transit warehouse is never an operational warehouse", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business, name: "North", branch_type: "sales") }
  let!(:main)    { business.warehouses.create!(name: "Main Depot", kind: "central") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5) }
  let!(:transit) { Inventory::TransitWarehouse.for!(business, actor: owner) }

  def transit_traces(html)
    doc = Nokogiri::HTML(html)
    traces = []
    traces << "option" if doc.css("option[value='#{transit.id}']").any?
    traces << "checkbox" if doc.css("input[type='checkbox'][value='#{transit.id}']").any?
    traces << "reserved name" if html.include?(Warehouse::TRANSIT_NAME)
    traces << "warehouse link" if doc.css("a[href='#{inventory_warehouse_path(transit)}']").any?
    traces
  end

  describe "pages an owner opens" do
    before { sign_in owner }

    {
      "warehouses list"           => -> { inventory_warehouses_path },
      "new stock transfer"        => -> { new_inventory_stock_transfer_path },
      "new stock issue"           => -> { new_inventory_stock_issue_path },
      "new stock adjustment"      => -> { new_inventory_stock_adjustment_path },
      "new stock count"           => -> { new_inventory_stock_count_path },
      "new goods receipt"         => -> { new_inventory_goods_receipt_path },
      "new purchase request"      => -> { new_inventory_purchase_request_path },
      "inventory dashboard"       => -> { inventory_root_path },
      "current stock report"      => -> { inventory_current_stock_report_path },
      "movements report"          => -> { inventory_movements_report_path },
      "low stock report"          => -> { inventory_low_stock_report_path },
      "branch comparison report"  => -> { inventory_branch_comparison_report_path },
      "warehouse supplies"        => -> { inventory_warehouse_supplies_path },
      "product page"              => -> { inventory_product_path(product) },
      "availability reconciliation" => -> { inventory_availability_reconciliation_path },
      "new employee (warehouse access)" => -> { new_admin_user_path }
    }.each do |page, path|
      it "#{page}: no trace of the transit warehouse" do
        get instance_exec(&path)
        expect(response).to have_http_status(:ok)
        expect(transit_traces(response.body)).to be_empty
      end
    end

    # One request each: after a 404 the test sign-in is not carried to the next request.
    {
      "show"           => -> { inventory_warehouse_path(transit) },
      "edit"           => -> { edit_inventory_warehouse_path(transit) },
      "classification" => -> { new_inventory_warehouse_classification_path(warehouse_id: transit.id) }
    }.each do |page, path|
      it "the transit warehouse #{page} page is not found" do
        get instance_exec(&path)
        expect(response).to have_http_status(:not_found)
      end
    end

    it "transfer availability refuses the transit warehouse as either end" do
      get availability_inventory_stock_transfers_path(source_warehouse_id: transit.id, destination_warehouse_id: main.id,
                                                       product_ids: [ product.id ])
      expect(response).to redirect_to(root_path)
    end
  end

  describe "services never accept it from a caller" do
    it "WarehouseReach and IssueWarehouseReach refuse it, even for the owner" do
      expect(Inventory::WarehouseReach.permits?(owner, transit)).to be(false)
      expect(Inventory::WarehouseReach.permits?(owner, main, transit)).to be(false)
      reach = Inventory::IssueWarehouseReach.for(owner)
      expect(reach.issuable?(transit.id)).to be(false)
      expect(reach.warehouses).not_to include(transit)
    end

    it "stock transfer drafts refuse it as source or destination" do
      [ { source_warehouse_id: transit.id, destination_warehouse_id: main.id },
        { source_warehouse_id: main.id, destination_warehouse_id: transit.id } ].each do |ends|
        result = Inventory::StockTransferDraftService.new(
          actor: owner, attributes: ends.merge(items_attributes: { "0" => { product_id: product.id, quantity: 1 } })
        ).call
        expect(result).not_to be_ok
      end
      expect(StockTransfer.count).to eq(0)
    end

    it "stock counts refuse it" do
      result = Inventory::StockCountCreator.new(actor: owner, warehouse_id: transit.id, counted_on: Date.current).call
      expect(result).not_to be_ok
      expect(StockCount.count).to eq(0)
    end

    it "adjustments refuse it" do
      adjustment = business.stock_adjustments.build(warehouse: transit, adjusted_on: Date.current, reason: "damaged", created_by: owner)
      adjustment.items.build(product: product, quantity_difference: 1)
      expect(Inventory::AdjustmentPoster.new(adjustment, actor: owner).call).not_to be_ok
      expect(InventoryMovement.where(warehouse: transit)).to be_empty
    end

    it "warehouse assignments refuse it and change nothing" do
      employee = create(:user, business: business)
      expect { Inventory::UserWarehouseAssignments.assign(user: employee, warehouse_ids: [ transit.id ], actor: owner) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(employee.warehouse_assignments).to be_empty
    end

    it "the warehouse policy refuses every instance action on it" do
      policy = WarehousePolicy.new(owner, transit)
      expect([ policy.show?, policy.update?, policy.destroy?, policy.classify? ]).to all(be(false))
      expect(WarehousePolicy::Scope.new(owner, Warehouse).resolve).not_to include(transit)
    end

    it "fail-closed warehouse access never lists it" do
      store_warehouse_access_fail_closed!(business)
      employee = create(:user, business: business)
      WarehouseAssignment.create!(user: employee, warehouse: main)
      expect(Inventory::WarehouseAccess.new(employee).warehouse_ids).to eq([ main.id ])
    end
  end
end
