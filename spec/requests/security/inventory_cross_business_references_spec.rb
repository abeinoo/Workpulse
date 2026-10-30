require "rails_helper"

# IP-1 (SaaS audit Phase 1, 2026-10-29): inventory documents take warehouse and
# product ids straight from form params. A user whose warehouse access is
# unrestricted — the business owner, or anyone with no warehouse assignments
# (User#inventory_warehouse_ids returns nil) — skips the only controller check,
# Inventory::BaseController#ensure_warehouses_accessible!. Every reference must
# still belong to the actor's own business: a document naming another
# business's warehouse or product is refused, nothing is written to either
# business's stock ledger, and the refusal never reveals the other business's
# on-hand quantity.
RSpec.describe "Inventory cross-business references (IP-1)", type: :request do
  let(:foreign_on_hand) { 4321 }

  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  let!(:owner) { create(:user, :owner, business: business) }
  # Full inventory rights, no warehouse assignment → unrestricted warehouse access.
  let!(:unassigned_manager) do
    role = business.permission_roles.create!(name: "Inventory manager",
                                             permissions: %w[view_inventory manage_inventory])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let!(:own_warehouse)   { business.warehouses.create!(name: "Own Main") }
  let!(:own_warehouse_2) { business.warehouses.create!(name: "Own Branch") }
  let!(:own_branch)      { create(:branch, business: business) }
  let!(:own_product) do
    business.products.create!(name: "Own Shampoo", sku: "OWN-1", initial_cost_price: 10, average_cost_price: 10)
  end

  let!(:foreign_warehouse) { other.warehouses.create!(name: "Foreign Main") }
  let!(:foreign_product) do
    other.products.create!(name: "Foreign Serum", sku: "FOR-1", initial_cost_price: 7, average_cost_price: 7)
  end

  before do
    receive_stock(business, own_warehouse, own_product, 10, 10)
    receive_stock(other, foreign_warehouse, foreign_product, foreign_on_hand, 7)
  end

  def receive_stock(owning_business, warehouse, product, quantity, unit_cost)
    receipt = owning_business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: quantity, unit_cost: unit_cost)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call.ok?).to be(true)
  end

  # Everything a cross-business write could disturb: both ledgers, the other
  # business's valuation, and the money tables the inventory documents feed.
  def ledger_state
    {
      movements:              InventoryMovement.count,
      foreign_warehouse_rows: InventoryMovement.where(warehouse_id: foreign_warehouse.id).count,
      foreign_product_rows:   InventoryMovement.where(product_id: foreign_product.id).count,
      foreign_on_hand:        foreign_product.stock_in(foreign_warehouse),
      foreign_average_cost:   foreign_product.reload.average_cost_price,
      own_on_hand:            own_product.stock_in(own_warehouse),
      settlements:            FinancialSettlement.count,
      custody_transactions:   CustodyTransaction.count
    }
  end

  def documents_state
    {
      transfers:    StockTransfer.count,
      adjustments:  StockAdjustment.count,
      counts:       StockCount.count,
      count_items:  StockCountItem.count,
      receipts:     GoodsReceipt.count,
      issues:       StockIssue.count
    }
  end

  shared_examples "a refused cross-business reference" do
    it "refuses the document and leaves every ledger and record untouched", :aggregate_failures do
      sign_in actor
      before_ledger    = ledger_state
      before_documents = documents_state

      perform_request

      expect(response).to have_http_status(:unprocessable_entity)
      expect(documents_state).to eq(before_documents)
      expect(ledger_state).to eq(before_ledger)
    end

    it "does not reveal the other business's on-hand quantity" do
      sign_in actor
      perform_request

      expect(response.body).not_to include(foreign_on_hand.to_s)
    end
  end

  { "the owner" => :owner, "a manager with no warehouse assignments" => :unassigned_manager }.each do |label, actor_name|
    context "as #{label}" do
      let(:actor) { public_send(actor_name) }

      describe "stock transfers" do
        def transfer(source:, destination:, product:, quantity:)
          post inventory_stock_transfers_path, params: { stock_transfer: {
            source_warehouse_id: source.id, destination_warehouse_id: destination.id, transferred_on: Date.current,
            items_attributes: { "0" => { product_id: product.id, quantity: quantity } }
          } }
        end

        context "out of another business's warehouse" do
          let(:perform_request) do
            transfer(source: foreign_warehouse, destination: own_warehouse, product: foreign_product, quantity: 5)
          end

          it_behaves_like "a refused cross-business reference"
        end

        context "over the other business's on-hand (availability check would disclose it)" do
          let(:perform_request) do
            transfer(source: foreign_warehouse, destination: own_warehouse, product: foreign_product,
                     quantity: foreign_on_hand + 1000)
          end

          it_behaves_like "a refused cross-business reference"
        end

        context "into another business's warehouse" do
          let(:perform_request) do
            transfer(source: own_warehouse, destination: foreign_warehouse, product: own_product, quantity: 2)
          end

          it_behaves_like "a refused cross-business reference"
        end

        context "of another business's product between own warehouses" do
          let(:perform_request) do
            transfer(source: own_warehouse, destination: own_warehouse_2, product: foreign_product, quantity: 1)
          end

          it_behaves_like "a refused cross-business reference"
        end
      end

      describe "stock adjustments" do
        def adjust(warehouse:, product:, difference:, reason: "damaged", unit_cost: nil)
          post inventory_stock_adjustments_path, params: { stock_adjustment: {
            warehouse_id: warehouse.id, adjusted_on: Date.current, reason: reason,
            items_attributes: { "0" => { product_id: product.id, quantity_difference: difference, unit_cost: unit_cost }.compact }
          } }
        end

        context "in another business's warehouse" do
          let(:perform_request) do
            adjust(warehouse: foreign_warehouse, product: own_product, difference: 5, reason: "opening_balance", unit_cost: 3)
          end

          it_behaves_like "a refused cross-business reference"
        end

        context "removing more than the other business's on-hand (availability check would disclose it)" do
          let(:perform_request) do
            adjust(warehouse: foreign_warehouse, product: foreign_product, difference: -(foreign_on_hand + 1000))
          end

          it_behaves_like "a refused cross-business reference"
        end

        context "adding another business's product to an own warehouse (would revalue it)" do
          let(:perform_request) do
            adjust(warehouse: own_warehouse, product: foreign_product, difference: 5, reason: "opening_balance", unit_cost: 999)
          end

          it_behaves_like "a refused cross-business reference"
        end
      end

      describe "stock counts" do
        context "opening a count session on another business's warehouse" do
          let(:perform_request) do
            post inventory_stock_counts_path, params: { stock_count: {
              warehouse_id: foreign_warehouse.id, counted_on: Date.current
            } }
          end

          it_behaves_like "a refused cross-business reference"

          # Creating a session snapshots on-hand for every product; that must not
          # happen against another business's warehouse even though the session
          # is then refused.
          it "never reads stock levels in the other business's warehouse" do
            sign_in actor
            read_warehouses = []
            allow_any_instance_of(Inventory::StockLevels).to receive(:in_warehouse).and_wrap_original do |original, warehouse|
              read_warehouses << (warehouse.respond_to?(:id) ? warehouse.id : warehouse)
              original.call(warehouse)
            end

            perform_request

            expect(read_warehouses).not_to include(foreign_warehouse.id)
          end
        end

        context "adding another business's product to an own count (scanner row)" do
          let!(:count) do
            c = business.stock_counts.build(warehouse: own_warehouse, counted_on: Date.current, created_by: owner)
            c.items.build(product: own_product, system_quantity: 10)
            c.save!
            c
          end

          let(:perform_request) do
            patch inventory_stock_count_path(count), params: { stock_count: {
              items_attributes: { "0" => { product_id: foreign_product.id, counted_quantity: 1, system_quantity: 0 } }
            } }
          end

          it_behaves_like "a refused cross-business reference"
        end
      end

      describe "goods receipts" do
        def receive(warehouse:, product:)
          post inventory_goods_receipts_path, params: { goods_receipt: {
            warehouse_id: warehouse.id, received_on: Date.current, funding_source_kind: "company_cash",
            items_attributes: { "0" => { product_id: product.id, quantity: 3, unit_cost: 10 } }
          } }
        end

        context "into another business's warehouse" do
          let(:perform_request) { receive(warehouse: foreign_warehouse, product: own_product) }

          it_behaves_like "a refused cross-business reference"
        end

        context "of another business's product" do
          let(:perform_request) { receive(warehouse: own_warehouse, product: foreign_product) }

          it_behaves_like "a refused cross-business reference"
        end
      end

      describe "stock issues" do
        def issue(warehouse:, product:)
          post inventory_stock_issues_path, params: { stock_issue: {
            warehouse_id: warehouse.id, branch_id: own_branch.id, issued_on: Date.current,
            items_attributes: { "0" => { product_id: product.id, quantity: 1 } }
          } }
        end

        context "from another business's warehouse" do
          let(:perform_request) { issue(warehouse: foreign_warehouse, product: own_product) }

          it_behaves_like "a refused cross-business reference"
        end

        # Already guarded by StockIssueItem#product_in_same_business; kept as a regression.
        context "of another business's product" do
          let(:perform_request) { issue(warehouse: own_warehouse, product: foreign_product) }

          it_behaves_like "a refused cross-business reference"
        end
      end
    end
  end
end
