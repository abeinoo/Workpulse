require "rails_helper"

# The redesigned Stock Transfers index: summary cards and status navigation
# from the stored statuses, compact filters, the route / requester / items /
# status table, and a per-row actions menu that only offers what
# StockTransferPolicy allows for that transfer — each entry leading to the
# page where the action already lives. The workflow itself is unchanged.
RSpec.describe "Inventory::StockTransfers#index (redesign)", type: :request do
  let(:business) { create(:business) }
  let!(:branch)  { create(:branch, business: business, name: "North", branch_type: "sales") }
  let!(:source)  { business.warehouses.create!(name: "Main Depot", kind: "central") }
  let!(:dest)    { business.warehouses.create!(name: "North Store", kind: "branch", branch: branch) }
  let!(:far)     { business.warehouses.create!(name: "Far Store") }
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
  let(:manager) { role_user(*everything, name: "Manager") }
  let(:viewer)  { role_user(:view_stock_transfers, name: "Viewer") }

  before do
    [ source, dest, far ].each do |w|
      InventoryMovement.create!(business: business, product: product, warehouse: w, direction: :in, reason: :opening_balance,
                                quantity: 500, unit_cost: 10, occurred_on: Date.new(2026, 1, 1))
    end
  end

  def doc = Nokogiri::HTML(response.body)
  def rows = doc.css("[data-testid='transfer-history'] tr[data-transfer]")
  def numbers = rows.map { |r| r["data-transfer"] }
  def row_for(t) = doc.at_css("[data-testid='transfer-history'] tr[data-transfer='#{t.transfer_number}']")
  def actions_for(t) = row_for(t).css("[data-transfer-action]").map { |a| a["data-transfer-action"] }
  def summary(key) = doc.at_css("[data-summary='#{key}'] .stt-summary__value").text.strip
  def tab_count(status) = doc.at_css("[data-status-filter='#{status}'] .badge")&.text&.strip

  # A fixture-status transfer (draft / pending / direct approved / rejected / cancelled).
  def fixture(status, from: source, to: dest, by: manager, on: Date.current)
    t = business.stock_transfers.build(source_warehouse: from, destination_warehouse: to, created_by: by, transferred_on: on)
    t.items.build(product: product, quantity: 1)
    save_stock_transfer_in_status!(t, status, actor: by)
  end

  # A via-transit transfer driven through the real screens.
  def transit_transfer(stage, to: dest)
    sign_in manager
    post inventory_stock_transfers_path, params: {
      submit_after_save: "1",
      stock_transfer: { source_warehouse_id: source.id, destination_warehouse_id: to.id,
                        items_attributes: { "0" => { product_id: product.id, quantity: 2 } } }
    }
    t = business.stock_transfers.order(:id).last
    patch approve_inventory_stock_transfer_path(t)
    patch dispatch_goods_inventory_stock_transfer_path(t) if stage == :in_transit
    t.reload.tap { |r| expect(r.status).to eq(stage.to_s) }
  end

  describe "summary and status navigation" do
    let!(:draft)     { fixture(:draft) }
    let!(:pending)   { fixture(:pending_approval) }
    let!(:posted)    { fixture(:approved) }
    let!(:rejected)  { fixture(:rejected) }
    let!(:cancelled) { fixture(:cancelled) }
    let!(:awaiting)  { transit_transfer(:awaiting_dispatch) }
    let!(:moving)    { transit_transfer(:in_transit) }

    it "counts the stored statuses in the summary cards and the tabs" do
      sign_in manager
      get inventory_stock_transfers_path

      expect(summary("total")).to eq("7")
      expect(summary("pending_approval")).to eq("1")
      expect(summary("awaiting_dispatch")).to eq("1")
      expect(summary("in_transit")).to eq("1")
      expect(summary("discrepancy")).to eq("0")
      expect(summary("received")).to eq("0")
      expect(tab_count("all")).to eq("7")
      expect(tab_count("draft")).to eq("1")
      expect(tab_count("approved")).to eq("1")
      expect(tab_count("rejected")).to eq("1")
      expect(tab_count("cancelled")).to eq("1")
    end

    it "offers every existing status filter exactly once, and no other" do
      sign_in manager
      get inventory_stock_transfers_path

      offered = doc.css("[data-status-filter]").map { |a| a["data-status-filter"] } - [ "all" ]
      expect(offered).to match_array(Inventory::StockTransferHistory::STATUS_FILTERS)
      expect(offered.uniq.size).to eq(offered.size)
    end

    it "filters by status from a tab or a summary card, and marks it current" do
      sign_in manager
      get inventory_stock_transfers_path(status: "awaiting_dispatch")

      expect(numbers).to eq([ awaiting.transfer_number ])
      expect(doc.at_css("[data-status-filter='awaiting_dispatch']")["aria-current"]).to eq("page")
      expect(doc.at_css("[data-summary='awaiting_dispatch']")["class"]).to include("is-active")
      expect(doc.at_css("[data-summary='pending_approval']")["href"]).to include("status=pending_approval")
    end

    it "keeps the summary on the whole list while filters narrow the table" do
      sign_in manager
      get inventory_stock_transfers_path(status: "draft", q: draft.transfer_number)

      expect(numbers).to eq([ draft.transfer_number ])
      expect(summary("total")).to eq("7")
    end

    it "scopes the cards and counts to the transfers the viewer may see" do
      fixture(:pending_approval, from: far, to: source)
      sign_in role_user(:view_stock_transfers, warehouses: [ far ])
      get inventory_stock_transfers_path

      expect(summary("total")).to eq("1")
      expect(summary("pending_approval")).to eq("1")
      expect(tab_count("draft")).to eq("0")
      expect(numbers.size).to eq(1)
    end
  end

  describe "filters" do
    it "combines search, route, requester and dates" do
      mine   = fixture(:draft, from: source, to: dest, by: viewer, on: Date.current)
      fixture(:draft, from: source, to: far, by: viewer, on: Date.current)
      fixture(:draft, from: source, to: dest, by: manager, on: Date.current)
      fixture(:draft, from: source, to: dest, by: viewer, on: Date.current - 10)
      sign_in manager

      get inventory_stock_transfers_path(q: "SH-1", source_warehouse_id: source.id, destination_warehouse_id: dest.id,
                                         person_id: viewer.id, from: (Date.current - 1).iso8601, to: Date.current.iso8601)
      expect(numbers).to eq([ mine.transfer_number ])
    end

    it "opens More filters only when one of its filters is set" do
      sign_in manager
      get inventory_stock_transfers_path
      expect(doc.at_css("[data-testid='more-filters']")["open"]).to be_nil

      get inventory_stock_transfers_path(person_id: manager.id)
      expect(doc.at_css("[data-testid='more-filters']")).to have_attribute("open")
    end

    it "resets the filters but keeps the status tab" do
      sign_in manager
      get inventory_stock_transfers_path(status: "draft", q: "zzz")

      expect(doc.at_css("[data-testid='reset-filters']")["href"]).to eq(inventory_stock_transfers_path(status: "draft"))
      expect(doc.at_css("[data-testid='transfers-empty']").text).to include(I18n.t("inventory.stock_transfers.history.no_match"))
    end

    it "submits without a page, so a new filter starts on page 1" do
      sign_in manager
      get inventory_stock_transfers_path(page: 2)

      form = doc.at_css("[data-testid='history-filters']")
      expect(form.css("input[name=page]")).to be_empty
    end
  end

  describe "pagination" do
    it "pages 25 rows at a time and keeps the filters in the page links" do
      26.times { fixture(:draft) }
      sign_in manager

      get inventory_stock_transfers_path(status: "draft")
      expect(rows.size).to eq(25)
      expect(doc.at_css("[data-testid='transfer-count']").text).to include("26")
      page_links = doc.css("a[href*='page=2']").map { |a| a["href"] }
      expect(page_links).to all(include("status=draft"))

      get inventory_stock_transfers_path(status: "draft", page: 2)
      expect(rows.size).to eq(1)
    end
  end

  describe "rows and navigation" do
    it "links the transfer number to its page and shows the route, requester and line count" do
      t = fixture(:pending_approval)
      sign_in manager
      get inventory_stock_transfers_path

      row = row_for(t)
      expect(row.at_css("[data-testid='transfer-link']")["href"]).to eq(inventory_stock_transfer_path(t))
      expect(row.at_css(".stt-route__end--source .stt-route__name").text).to eq("Main Depot")
      expect(row.at_css(".stt-route__end--destination .stt-route__name").text).to eq("North Store")
      expect(row.at_css(".stt-route__end--destination .stt-route__branch").text).to eq("North")
      expect(row.text).to include("Manager")
      expect(row.at_css(".stt-table__num").text.strip).to eq("1")
      expect(row.at_css("[data-transfer-status='pending_approval']")).to be_present
    end
  end

  describe "row actions follow the policy" do
    it "gives a view-only user nothing but View" do
      t = fixture(:pending_approval)
      sign_in viewer
      get inventory_stock_transfers_path

      expect(actions_for(t)).to eq(%w[view])
    end

    it "offers the manager what each status allows" do
      draft    = fixture(:draft)
      pending  = fixture(:pending_approval)
      posted   = fixture(:approved)
      awaiting = transit_transfer(:awaiting_dispatch)
      moving   = transit_transfer(:in_transit)
      sign_in manager
      get inventory_stock_transfers_path

      expect(actions_for(draft)).to eq(%w[view edit submit cancel])
      expect(actions_for(pending)).to eq(%w[view edit review cancel])
      expect(actions_for(awaiting)).to eq(%w[view dispatch cancel])
      expect(actions_for(moving)).to eq(%w[view receive])
      expect(actions_for(posted)).to eq(%w[view])
    end

    it "offers dispatch and receipt only on the viewer's own side" do
      awaiting = transit_transfer(:awaiting_dispatch)
      moving   = transit_transfer(:in_transit)
      dispatcher = role_user(:view_stock_transfers, :dispatch_stock_transfers, :receive_stock_transfers, warehouses: [ source ])
      sign_in dispatcher
      get inventory_stock_transfers_path

      expect(actions_for(awaiting)).to eq(%w[view dispatch])
      expect(actions_for(moving)).to eq(%w[view]) # its destination is not theirs
    end

    it "leads every entry to the edit form or the transfer page's own action" do
      pending = fixture(:pending_approval)
      moving  = transit_transfer(:in_transit)
      sign_in manager
      get inventory_stock_transfers_path

      hrefs = row_for(pending).css("[data-transfer-action]").to_h { |a| [ a["data-transfer-action"], a["href"] ] }
      expect(hrefs).to eq(
        "view" => inventory_stock_transfer_path(pending), "edit" => edit_inventory_stock_transfer_path(pending),
        "review" => inventory_stock_transfer_path(pending), "cancel" => inventory_stock_transfer_path(pending, anchor: "cancel-transfer")
      )
      expect(row_for(moving).at_css("[data-transfer-action='receive']")["href"])
        .to eq(inventory_stock_transfer_path(moving, anchor: "receive-title"))

      get inventory_stock_transfer_path(pending)
      expect(doc.at_css("#cancel-transfer")).to be_present
      get inventory_stock_transfer_path(moving)
      expect(doc.at_css("#receive-title")).to be_present
    end

    it "never performs an action from the list" do
      fixture(:pending_approval)
      sign_in manager
      get inventory_stock_transfers_path

      expect(doc.css("[data-testid='transfer-history'] form")).to be_empty
      expect(doc.css("[data-testid='transfer-history'] [data-turbo-method]")).to be_empty
    end

    it "does not add a database round trip per row for a warehouse-scoped user" do
      user = role_user(*everything, warehouses: [ source, dest ])
      sign_in user
      queries = lambda do
        count = 0
        counter = ->(*, payload) { count += 1 unless payload[:cached] || payload[:name] == "SCHEMA" }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get inventory_stock_transfers_path }
        count
      end

      2.times { fixture(:pending_approval) }
      queries.call # warm-up: the layout's per-session loads
      few = queries.call
      10.times { fixture(:pending_approval) }
      expect(queries.call).to eq(few)
    end
  end

  describe "header and empty states" do
    it "shows the New Transfer action and its empty-state call to action only to creators" do
      sign_in manager
      get inventory_stock_transfers_path
      expect(doc.at_css("[data-testid='new-transfer']")["href"]).to eq(new_inventory_stock_transfer_path)
      expect(doc.at_css("[data-testid='transfers-empty']").to_html).to include(new_inventory_stock_transfer_path)

      sign_in viewer
      get inventory_stock_transfers_path
      expect(doc.at_css("[data-testid='new-transfer']")).to be_nil
      expect(doc.at_css("[data-testid='transfers-empty']").to_html).not_to include(new_inventory_stock_transfer_path)
    end
  end

  it "renders in Arabic, right to left, with every new string translated" do
    fixture(:pending_approval)
    transit_transfer(:in_transit)
    manager.update_column(:preferred_locale, "ar")
    sign_in manager
    get inventory_stock_transfers_path(person_id: manager.id)

    expect(doc.at_css("html")["dir"]).to eq("rtl")
    expect(response.body).to include("تحويلات المخزون", "إجمالي التحويلات", "قيد التنفيذ", "مرشحات إضافية", "إجراءات التحويل")
    expect(response.body).not_to include("translation missing", "Translation missing")
  end
end
