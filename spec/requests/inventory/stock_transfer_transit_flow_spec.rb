require "rails_helper"

# The redesigned Stock Transfer screens over HTTP: every stage renders, every
# action goes through its service, the In Transit / Receiving page and the
# dashboard's counts use the same queues, history filters and the timeline work, and
# EN / AR (RTL) both render.
RSpec.describe "Stock transfer transit workflow (HTTP)", type: :request do
  let(:business) { create(:business) }
  let!(:branch)  { create(:branch, business: business, name: "North", branch_type: "sales") }
  let!(:source)  { business.warehouses.create!(name: "Main Depot", kind: "central") }
  let!(:dest)    { business.warehouses.create!(name: "North Store", kind: "branch", branch: branch) }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }

  def role_user(*permissions, warehouses: [], name: "U#{SecureRandom.hex(2)}")
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s))
    create(:user, business: business, first_name: name).tap do |u|
      u.update_column(:permission_role_id, role.id)
      warehouses.each { |w| WarehouseAssignment.create!(user: u, warehouse: w) }
    end
  end

  let(:everything) do
    %i[view_stock_transfers create_stock_transfers approve_stock_transfers edit_pending_stock_transfers reject_stock_transfers
       cancel_stock_transfers dispatch_stock_transfers receive_stock_transfers resolve_stock_transfer_discrepancies]
  end
  let(:manager)    { role_user(*everything, name: "Manager") }
  let(:dispatcher) { role_user(:view_stock_transfers, :dispatch_stock_transfers, warehouses: [ source ], name: "Dispatcher") }
  let(:receiver)   { role_user(:view_stock_transfers, :receive_stock_transfers, warehouses: [ dest ], name: "Receiver") }

  before do
    InventoryMovement.create!(business: business, product: product, warehouse: source, direction: :in, reason: :opening_balance,
                              quantity: 100, unit_cost: 10, occurred_on: Date.new(2026, 1, 1))
  end

  def doc = Nokogiri::HTML(response.body)
  def transfer = business.stock_transfers.order(:id).last
  def transit = Inventory::TransitWarehouse.find_for(business)

  def create_and_submit(qty = 10)
    sign_in manager
    post inventory_stock_transfers_path, params: {
      submit_after_save: "1",
      stock_transfer: { source_warehouse_id: source.id, destination_warehouse_id: dest.id,
                        items_attributes: { "0" => { product_id: product.id, quantity: qty } } }
    }
    transfer
  end

  it "runs the whole lifecycle through the screens, rendering every stage" do
    t = create_and_submit(10)
    expect(t).to be_pending_approval
    expect(t.items.sole.requested_quantity).to eq(10)
    get inventory_stock_transfer_path(t)
    expect(response).to have_http_status(:ok)
    expect(doc.at_css("[data-testid='review-lines']")).to be_present

    patch approve_inventory_stock_transfer_path(t)
    expect(flash[:notice]).to eq(I18n.t("inventory.stock_transfers.outcomes.awaiting_dispatch"))
    expect(t.reload).to be_awaiting_dispatch
    get inventory_stock_transfer_path(t)
    expect(doc.at_css("[data-testid='dispatch-button']")).to be_present

    sign_in dispatcher
    patch dispatch_goods_inventory_stock_transfer_path(t)
    expect(t.reload).to be_in_transit
    expect(product.stock_in(transit)).to eq(10)

    sign_in receiver
    get inventory_stock_transfer_path(t)
    expect(doc.at_css("[data-testid='receive-form']")).to be_present
    patch receive_inventory_stock_transfer_path(t), params: { receive: { t.items.first.id => "6" }, receipt_notes: "box damaged" }
    expect(flash[:notice]).to eq(I18n.t("inventory.stock_transfers.outcomes.in_transit"))
    expect(t.reload).to be_partially_received
    patch receive_inventory_stock_transfer_path(t), params: { receive: { t.items.first.id => "1" }, close_shortfall: "1" }
    expect(t.reload).to be_discrepancy

    sign_in manager
    get inventory_stock_transfer_path(t)
    expect(doc.at_css("[data-testid='resolve-form']")).to be_present
    patch resolve_inventory_stock_transfer_path(t), params: { resolve: { t.items.first.id => { write_off: "", return_to_source: "3" } },
                                                              resolution_reason: "Returned by courier" }
    expect(t.reload).to be_received
    expect(product.stock_in(source)).to eq(93)
    expect(product.stock_in(dest)).to eq(7)
    expect(product.stock_in(transit)).to eq(0)

    get inventory_stock_transfer_path(t)
    expect(response).to have_http_status(:ok)
    events = doc.css("[data-testid='transfer-timeline'] [data-timeline-event]").map { |e| e["data-timeline-event"] }
    expect(events).to eq(%w[created submitted approved dispatched received_partially received_with_shortfall resolved])
    expect(doc.at_css("[data-testid='ledger-history']").text).to include("box damaged", "Returned by courier")
  end

  it "refuses each step to users without its permission or warehouse side" do
    t = create_and_submit
    sign_in receiver
    patch approve_inventory_stock_transfer_path(t)
    expect(response).to redirect_to(root_path)
    sign_in manager
    patch approve_inventory_stock_transfer_path(t)

    sign_in receiver
    patch dispatch_goods_inventory_stock_transfer_path(t)
    expect(response).to redirect_to(root_path)
    expect(t.reload).to be_awaiting_dispatch

    sign_in role_user(:view_stock_transfers, :dispatch_stock_transfers, warehouses: [ dest ])
    patch dispatch_goods_inventory_stock_transfer_path(t)
    expect(response).to redirect_to(root_path)

    sign_in role_user(:view_inventory, :manage_inventory, :manage_stock_transfers)
    patch dispatch_goods_inventory_stock_transfer_path(t)
    expect(response).to redirect_to(root_path)
    expect(t.reload).to be_awaiting_dispatch
  end

# Transfers in Transit is not a navigation entry: the dashboard's "Needs
# action" items open it, counted from the same queues as its lists.
describe "Transfers in Transit page" do
  def nav_hrefs = doc.css(".ws__rail a.ws__rail-item, .ws__tabs a.ws__tab, .ws__more-menu a.ws__more-item").map { |a| a["href"] }

  it "lists what waits for each user, from the same queues as the dashboard's counts — with no navigation entry or badge" do
    t = create_and_submit
    patch approve_inventory_stock_transfer_path(t)

    sign_in dispatcher
    get inventory_transfers_in_transit_index_path
    expect(response).to have_http_status(:ok)
    expect(doc.css("[data-testid='in-transit-list'] tr[data-transfer]").map { |r| r["data-transfer"] }).to eq([ t.transfer_number ])
    expect(nav_hrefs).not_to include(inventory_transfers_in_transit_index_path)
    expect(nav_hrefs).to include(inventory_stock_transfers_path)
    expect(doc.css("[data-testid^='workspace-badge-']")).to be_empty

    patch dispatch_goods_inventory_stock_transfer_path(t)
    sign_in role_user(:view_inventory, :view_stock_transfers, :receive_stock_transfers, warehouses: [ dest ])
    get inventory_transfers_in_transit_index_path(tab: "to_receive")
    expect(doc.css("[data-testid='in-transit-list'] tr[data-transfer]").size).to eq(1)
    get inventory_root_path
    expect(doc.css("a").map { |a| a["href"] }).to include(inventory_transfers_in_transit_index_path(tab: "to_receive"))
  end

  it "is closed to users who neither dispatch, receive nor resolve (legacy broad permissions included)" do
    sign_in role_user(:view_inventory, :manage_inventory, :manage_stock_transfers)
    get inventory_transfers_in_transit_index_path
    expect(response).to redirect_to(root_path)
  end

  it "never lists a transfer whose side the user cannot reach" do
    t = create_and_submit
    patch approve_inventory_stock_transfer_path(t)
    sign_in role_user(:view_stock_transfers, :dispatch_stock_transfers, warehouses: [ dest ])
    get inventory_transfers_in_transit_index_path(tab: "to_dispatch")
    expect(doc.at_css("[data-testid='in-transit-empty']")).to be_present
  end
end

  describe "history" do
    it "filters by status (incl. derived partially received), warehouse, person, number / product and date" do
      t = create_and_submit
      other = create_and_submit(2)
      patch approve_inventory_stock_transfer_path(t)

      get inventory_stock_transfers_path(status: "awaiting_dispatch")
      expect(doc.css("[data-testid='transfer-history'] tr[data-transfer]").map { |r| r["data-transfer"] }).to eq([ t.transfer_number ])
      get inventory_stock_transfers_path(q: other.transfer_number)
      expect(doc.css("[data-testid='transfer-history'] tr[data-transfer]").map { |r| r["data-transfer"] }).to eq([ other.transfer_number ])
      get inventory_stock_transfers_path(q: "SH-1")
      expect(doc.css("[data-testid='transfer-history'] tr[data-transfer]").size).to eq(2)
      get inventory_stock_transfers_path(destination_warehouse_id: source.id)
      expect(doc.css("[data-testid='transfer-history'] tr[data-transfer]")).to be_empty
      get inventory_stock_transfers_path(person_id: manager.id, from: Date.current.iso8601, to: Date.current.iso8601)
      expect(doc.css("[data-testid='transfer-history'] tr[data-transfer]").size).to eq(2)
      get inventory_stock_transfers_path(status: "partially_received")
      expect(response).to have_http_status(:ok)
    end
  end

  it "serves the replenishment suggestions as the modal body, for reachable warehouses only" do
    ProductWarehouseSetting.create!(product: product, warehouse: dest, business: business, low_stock_level: 5, reorder_quantity: 12)
    sign_in manager
    get replenishment_inventory_stock_transfers_path(source_warehouse_id: source.id, destination_warehouse_id: dest.id)
    expect(response).to have_http_status(:ok)
    row = doc.at_css("[data-replenishment-row]")
    expect(JSON.parse(row["data-product"])["id"]).to eq(product.id)
    expect(row.at_css("[data-replenishment-quantity]")["value"]).to eq("12")

    sign_in role_user(:view_stock_transfers, :create_stock_transfers, warehouses: [ source ])
    get replenishment_inventory_stock_transfers_path(source_warehouse_id: source.id, destination_warehouse_id: dest.id)
    expect(response).to redirect_to(root_path)
  end

  it "shows the transfer stages on the inventory dashboard" do
    t = create_and_submit
    patch approve_inventory_stock_transfer_path(t)
    sign_in role_user(:view_inventory, *everything)
    get inventory_root_path
    card = doc.at_css("[data-testid='dashboard-transfers']")
    expect(card.at_css("[data-stage='awaiting_dispatch'] .stat-card__value").text.strip).to eq("1")
    expect(card.at_css("[data-stage='pending_approval'] .stat-card__value").text.strip).to eq("0")
  end

  it "renders every stage in Arabic, right to left" do
    t = create_and_submit
    manager.update_column(:preferred_locale, "ar")
    sign_in manager
    get new_inventory_stock_transfer_path
    expect(doc.at_css("html")["dir"]).to eq("rtl")
    expect(response.body).to include("جلب المنتجات منخفضة المخزون")
    get inventory_stock_transfer_path(t)
    expect(response.body).to include("بانتظار الاعتماد")
    patch approve_inventory_stock_transfer_path(t)
    get inventory_transfers_in_transit_index_path
    expect(response.body).to include("التحويلات بالطريق")
    expect(response.body).not_to include("translation missing")
  end
end
