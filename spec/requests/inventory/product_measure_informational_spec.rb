require "rails_helper"

# Unit of Measure and Amount are informational product attributes. Changing
# them is, for inventory, exactly like changing the description or SKU: it
# updates the product and nothing else — no conversion, no movement, no
# recalculation; balances, history, reservations, average cost and value stay
# as they were, and every inventory workflow behaves the same afterwards.
RSpec.describe "Product Unit of Measure and Amount are informational only", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:main)    { business.warehouses.create!(name: "Main", kind: "central") }
  let!(:annex)   { business.warehouses.create!(name: "Annex") }
  let(:branch)   { create(:branch, business: business) }
  let!(:product) do
    business.products.create!(name: "Rope", sku: "RP-1", initial_cost_price: 0, average_cost_price: 0,
                              unit_of_measure: "pieces", measure_amount: 10)
  end

  def receive!(quantity, unit_cost, warehouse: main)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: quantity, unit_cost: unit_cost)
    expect(Inventory::GoodsReceiptPoster.new(receipt, actor: owner).call).to be_ok
    receipt
  end

  def issue!(quantity)
    issue = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current)
    issue.items.build(product: product, quantity: quantity)
    expect(approve_and_post_stock_issue(issue)).to be_ok
    issue
  end

  def approved_issue(quantity)
    issue = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current)
    issue.items.build(product: product, quantity: quantity)
    save_stock_issue_in_status!(issue, :approved)
  end

  def transfer!(quantity)
    transfer = business.stock_transfers.build(source_warehouse: main, destination_warehouse: annex, transferred_on: Date.current, created_by: owner)
    transfer.items.build(product: product, quantity: quantity)
    expect(post_stock_transfer(transfer)).to be_ok
  end

  def edit_measure!(unit, amount)
    patch inventory_product_path(product), params: { product: { name: product.name, sku: product.sku, unit_of_measure: unit, measure_amount: amount } }
    expect(response).to redirect_to(inventory_product_path(product))
  end

  def table_count(table) = ActiveRecord::Base.connection.select_value("SELECT count(*) FROM #{table}").to_i

  # Everything inventory knows about the product.
  def inventory_state
    product.reload
    { balances: Inventory::StockLevels.new(product).by_warehouse, stock: product.current_stock,
      movements: InventoryMovement.where(product_id: product.id).order(:id).map(&:attributes),
      receipt_lines: GoodsReceiptItem.where(product_id: product.id).order(:id).map(&:attributes),
      issue_lines: StockIssueItem.where(product_id: product.id).order(:id).map(&:attributes),
      reserved: Inventory::StockAvailability.reserved_by(warehouse_ids: [ main.id ], product_ids: [ product.id ]),
      average: product.average_cost_price, value: product.current_stock * product.average_cost_price,
      average_changes: InventoryAverageCostChange.where(product_id: product.id).count }
  end

  before { sign_in owner }

  context "the mandatory scenario: 10 pieces in stock, Pieces → Feet and Amount 10 → 60" do
    before do
      receive!(12, 5)  # 12 pcs at 5.00
      receive!(3, 10)  # average (60 + 30) / 15 = 6.00
      issue!(5)        # 10 pcs left
    end

    it "updates only the product's information: stock, balances, history, reservations, average cost and value are untouched" do
      expect(product.reload.current_stock).to eq(10)
      before = inventory_state
      counts = %w[inventory_movements inventory_unit_conversions inventory_unit_conversion_lines inventory_packaging_entries product_packaging_levels]
                 .to_h { |table| [ table, table_count(table) ] }

      edit_measure!("ft", "60")

      expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "ft", 60 ])
      expect(inventory_state).to eq(before)
      expect(before[:stock]).to eq(10)
      expect(before[:average]).to eq(6)
      expect(counts.keys.to_h { |table| [ table, table_count(table) ] }).to eq(counts) # no movement, conversion or packaging row
    end

    it "receiving, issuing, transferring and stocktaking afterwards behave exactly as before the edit" do
      edit_measure!("ft", "60")

      receive!(5, 9)                                     # (10 × 6 + 5 × 9) / 15 = 7
      expect([ product.reload.current_stock, product.average_cost_price ]).to eq([ 15, 7 ])
      issue = issue!(4)
      expect([ issue.items.sole.quantity, issue.items.sole.unit_cost, product.reload.current_stock ]).to eq([ 4, 7, 11 ])
      transfer!(3)
      expect([ product.stock_in(main), product.stock_in(annex), product.reload.average_cost_price ]).to eq([ 8, 3, 7 ])

      counter  = user_with_stock_permissions(business, :view_inventory, :manage_stock_counts)
      approver = user_with_stock_permissions(business, :view_inventory, :post_stock_counts)
      count = record_stock_count!(business: business, warehouse: main, counter: counter, lines: [ [ product, 6 ] ], complete: true)
      expect(approve_stock_count(count, approver)).to be_ok
      expect([ product.stock_in(main), product.reload.current_stock ]).to eq([ 6, 9 ])
    end

    it "reservations and availability are unchanged, and still protect approved issues" do
      approved_issue(7)
      before = inventory_state
      edit_measure!("ft", "60")
      expect(inventory_state).to eq(before)
      expect(before[:reserved]).to eq([ main.id, product.id ] => 7)

      transfer = business.stock_transfers.build(source_warehouse: main, destination_warehouse: annex, transferred_on: Date.current, created_by: owner)
      transfer.items.build(product: product, quantity: 4)  # 10 on hand − 4 < 7 reserved
      expect(post_stock_transfer(transfer)).not_to be_ok
      expect(product.reload.stock_in(main)).to eq(10)
    end

    it "the Amount alone changes freely, and so does the unit back and forth — still nothing in inventory moves" do
      before = inventory_state
      edit_measure!("pieces", "")
      edit_measure!("kg", "2.5")
      edit_measure!("pieces", "")
      expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "pieces", nil ])
      expect(inventory_state).to eq(before)
    end
  end

  # The reported example: each bottle of shampoo contains 1 litre (Measure l,
  # Amount 1). Inventory counts bottles — never litres.
  context "the shampoo example: 3 bottles of 1 l each" do
    let!(:product) do
      business.products.create!(name: "Shampoo", sku: "SH-9", initial_cost_price: 0, average_cost_price: 0,
                                unit_of_measure: "l", measure_amount: 1)
    end

    def doc = Nokogiri::HTML(response.body)

    it "issuing 1 bottle leaves 2 bottles; receipts, transfers, counts, reservations and costs all count bottles" do
      receipt = receive!(3, 50)                                         # 3 bottles at 50.00 each
      expect([ product.reload.current_stock, product.average_cost_price ]).to eq([ 3, 50 ])

      issue = issue!(1)
      expect([ product.reload.current_stock, issue.items.sole.quantity, issue.items.sole.unit_cost ]).to eq([ 2, 1, 50 ])
      expect(product.current_stock * product.average_cost_price).to eq(100) # 2 bottles × 50, the Amount never multiplies

      receive!(5, 50)
      transfer!(2)
      expect([ product.stock_in(main), product.stock_in(annex) ]).to eq([ 5, 2 ])

      counter  = user_with_stock_permissions(business, :view_inventory, :manage_stock_counts)
      approver = user_with_stock_permissions(business, :view_inventory, :post_stock_counts)
      count = record_stock_count!(business: business, warehouse: main, counter: counter, lines: [ [ product, 5 ] ], complete: true)
      expect(approve_stock_count(count, approver)).to be_ok             # 5 bottles counted = 5 on hand: no difference
      expect(count.reload.stock_adjustments).to be_empty

      approved_issue(4)
      before = inventory_state
      expect(before[:reserved]).to eq([ main.id, product.id ] => 4)

      edit_measure!("ml", "1000")                                       # same bottle described in ml
      expect(inventory_state).to eq(before)
      expect([ product.reload.current_stock, product.average_cost_price ]).to eq([ 7, 50 ])

      get inventory_product_path(product)
      expect(doc.at_css("[data-testid='product-measure']").text.squish).to include("1000 ml")
      expect(doc.text.squish).not_to match(/\b7 (ml|l)\b/)
      get inventory_goods_receipt_path(receipt)
      expect(doc.css("td").map { |td| td.text.squish }).to include("3")
      expect(doc.text.squish).not_to match(/\b3 (ml|l)\b/)
    end
  end

  it "a product still carrying a legacy active packaging level saves its Amount: no packaging rule blocks it" do
    receive!(10, 5)
    ActiveRecord::Base.connection.execute(<<~SQL)
      INSERT INTO product_packaging_levels (business_id, product_id, position, package_unit, contains_quantity, base_quantity, status, created_at, updated_at)
      VALUES (#{business.id}, #{product.id}, 1, 'carton', 10, 10, 'active', now(), now())
    SQL
    before = inventory_state

    edit_measure!("ft", "60")
    # The old structure checks were DEFERRED constraint triggers, which fire
    # only at COMMIT — never inside a transactional test. Fire every deferred
    # check now: with the packaging rule still in the database this raises
    # "measure_amount of product … must equal its innermost packaging content".
    expect { ActiveRecord::Base.connection.execute("SET CONSTRAINTS ALL IMMEDIATE") }.not_to raise_error

    expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "ft", 60 ])
    expect(inventory_state).to eq(before)
    expect(table_count("product_packaging_levels")).to eq(1) # the historical row is kept as it was
  end
end
