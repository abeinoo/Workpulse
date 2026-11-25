require "rails_helper"

# Transfer Approvals queue + workspace badge. Both come from ONE relation
# (Inventory::PendingStockTransferApprovals): approve_stock_transfers only,
# pending only, both warehouses reachable. Read-only: decisions stay on the
# transfer's own page.
RSpec.describe "Inventory::StockTransferApprovals", type: :request do
  let(:business)  { create(:business) }
  let!(:north)    { create(:branch, business: business, name: "North Branch") }
  let!(:main)     { business.warehouses.create!(name: "Main Depot", kind: "central") }
  let!(:branch)   { business.warehouses.create!(name: "North Store", kind: "branch", branch: north) }
  let!(:far)      { business.warehouses.create!(name: "Far Store") }
  let!(:product)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1) }
  let(:requester) { user_with(:view_stock_transfers, :create_stock_transfers, name: "Requester") }

  def user_with(*permissions, warehouses: [], name: "Role #{SecureRandom.hex(3)}")
    role = business.permission_roles.create!(name: name, permissions: permissions.map(&:to_s))
    create(:user, business: business, first_name: name).tap do |u|
      u.update_column(:permission_role_id, role.id)
      warehouses.each { |w| WarehouseAssignment.create!(user: u, warehouse: w) }
    end
  end

  def approver(warehouses: []) = user_with(:view_stock_transfers, :approve_stock_transfers, warehouses: warehouses)

  # An approved fixture really posts: stock it in every warehouse.
  before do
    [ main, branch, far ].each do |w|
      InventoryMovement.create!(business: business, product: product, warehouse: w, direction: :in, reason: :opening_balance,
                                quantity: 100, unit_cost: 1, occurred_on: Date.new(2026, 1, 1))
    end
  end

  def transfer(status, from: main, to: branch, lines: 1)
    t = business.stock_transfers.build(source_warehouse: from, destination_warehouse: to, created_by: requester)
    lines.times { |i| t.items.build(product: i.zero? ? product : business.products.create!(name: "P#{i}", sku: "P-#{i}"), quantity: 1) }
    save_stock_transfer_in_status!(t, status, actor: requester)
  end

  def doc = Nokogiri::HTML(response.body)
  def queue_numbers = doc.css("[data-testid='approvals-queue'] tbody tr").map { |tr| tr["data-transfer"] }
  def queue_count = doc.at_css("[data-testid='approvals-queue-count']").text.to_i
  def approvals_links(selector) = doc.css(selector).select { |a| a["href"] == inventory_stock_transfer_approvals_path }
  def nav_links = doc.css(".ws__rail a.ws__rail-item, .ws__tabs a.ws__tab, .ws__more-menu a.ws__more-item")

  # The approvals badge's COUNT: a plain (ungrouped) count of pending_approval
  # transfers (the status may come as a bind value).
  def pending_count_query?(payload)
    sql = payload[:sql]
    values = Array(payload[:binds]).map { |b| b.respond_to?(:value_before_type_cast) ? b.value_before_type_cast : b }
    sql.start_with?("SELECT COUNT") && sql.include?('"stock_transfers"."status" =') && !sql.include?("GROUP BY") &&
      (sql.include?("pending_approval") || values.include?("pending_approval"))
  end

  def pending_count_queries
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if pending_count_query?(payload) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    queries
  end

  describe "the queue" do
    let!(:pending_main_branch) { transfer(:pending_approval, lines: 2) }
    let!(:pending_far)         { transfer(:pending_approval, from: far, to: branch) }
    let!(:draft)               { transfer(:draft) }
    let!(:approved)            { transfer(:approved) }
    let!(:rejected)            { transfer(:rejected) }

    it "lists only pending transfers, oldest submission first, with warehouses, branches, requester, time and line count" do
      sign_in approver
      get inventory_stock_transfer_approvals_path
      expect(response).to have_http_status(:ok)
      expect(queue_numbers).to eq([ pending_main_branch, pending_far ].map(&:transfer_number))

      row = doc.at_css("tr[data-transfer='#{pending_main_branch.transfer_number}']")
      expect(row.text).to include("Main Depot", "North Store", "North Branch", "Requester",
                                  I18n.l(pending_main_branch.submitted_at.in_time_zone(business.timezone_object || Time.zone), format: :short))
      expect(row.at_css("td[data-label='#{I18n.t('inventory.stock_transfer_approvals.lines')}']").text.strip).to eq("2")
      expect(row.at_css("a[href='#{inventory_stock_transfer_path(pending_main_branch)}']")).to be_present
      expect(row.css("form, button")).to be_empty # read-only
    end

    it "lists only transfers whose BOTH warehouses the approver reaches" do
      sign_in approver(warehouses: [ main, branch ])
      get inventory_stock_transfer_approvals_path
      expect(queue_numbers).to eq([ pending_main_branch.transfer_number ])
    end

    it "shows nothing when the approver reaches only one end of every transfer" do
      sign_in approver(warehouses: [ branch ])
      get inventory_stock_transfer_approvals_path
      expect(response).to have_http_status(:ok)
      expect(doc.at_css("[data-testid='approvals-queue-empty']")).to be_present
      expect(queue_count).to eq(0)
    end

    it "is the same relation as its count on the history page: queue rows == queue count" do
      sign_in approver(warehouses: [ main, branch ])
      get inventory_stock_transfer_approvals_path
      expect(queue_numbers.size).to eq(1)
      expect(queue_count).to eq(1)
      get inventory_stock_transfers_path
      expect(doc.at_css("[data-testid='pending-approval-count']").text).to include("1")
    end
  end

  describe "server-side authorization" do
    before { transfer(:pending_approval) }

    {
      "no transfer permission"           => %i[view_inventory],
      "transfer view only"               => %i[view_stock_transfers],
      "legacy manage_stock_transfers"    => %i[view_inventory manage_stock_transfers],
      "legacy manage_inventory"          => %i[view_inventory manage_inventory],
      "every other transfer permission"  => %i[view_stock_transfers create_stock_transfers edit_pending_stock_transfers
                                               reject_stock_transfers cancel_stock_transfers]
    }.each do |description, permissions|
      it "refuses a user with #{description}" do
        sign_in user_with(*permissions)
        get inventory_stock_transfer_approvals_path
        expect(response).to redirect_to(root_path)
      end
    end

    it "admits the owner" do
      sign_in create(:user, :owner, business: business)
      get inventory_stock_transfer_approvals_path
      expect(response).to have_http_status(:ok)
      expect(queue_count).to eq(1)
    end

    it "never shows another business's transfers" do
      foreign = create(:business)
      role = foreign.permission_roles.create!(name: "A", permissions: %w[view_stock_transfers approve_stock_transfers])
      sign_in create(:user, business: foreign).tap { |u| u.update_column(:permission_role_id, role.id) }
      get inventory_stock_transfer_approvals_path
      expect(queue_count).to eq(0)
    end
  end

  # The queue is not a navigation entry (Stock Transfers is): it opens from the dashboard's needs-action item and the history
  # page's pending link, both counted from the same relation.
  describe "entry points (no navigation entry, no badge)" do
    it "shows an approver no navigation entry and no badge, and links the queue from the history page" do
      2.times { transfer(:pending_approval) }
      sign_in approver
      get inventory_stock_transfers_path

      expect(approvals_links(".ws__rail a, .ws__tabs a, .ws__more-menu a")).to be_empty
      expect(nav_links.map { |a| a["href"] }).to include(inventory_stock_transfers_path) # the main entry stays
      expect(doc.css("[data-testid='workspace-badge-transfer_approvals']")).to be_empty
      link = doc.at_css("[data-testid='pending-approval-count']")
      expect(link["href"]).to eq(inventory_stock_transfer_approvals_path)
      expect(link.text).to include("2")
    end

    it "keeps the dashboard's links to the queue and the history" do
      transfer(:pending_approval)
      sign_in user_with(:view_inventory, :view_stock_transfers, :approve_stock_transfers)
      get inventory_root_path
      expect(response).to have_http_status(:ok)
      expect(approvals_links("a").size).to be >= 1
      expect(approvals_links(".ws__rail a, .ws__tabs a, .ws__more-menu a")).to be_empty
      expect(doc.css("[data-testid='dashboard-transfers'] a").map { |a| a["href"] }).to include(inventory_stock_transfers_path)
    end

    it "runs no count query for users without approve_stock_transfers" do
      transfer(:pending_approval)
      sign_in user_with(:view_inventory, :manage_inventory, :manage_stock_transfers)
      queries = pending_count_queries { get inventory_stock_transfers_path }

      expect(response).to have_http_status(:ok)
      expect(approvals_links("a")).to be_empty
      expect(queries).to be_empty
    end

    it "counts once per request" do
      transfer(:pending_approval)
      sign_in user_with(:view_inventory, :view_stock_transfers, :approve_stock_transfers) # may open the dashboard too
      expect(pending_count_queries { get inventory_root_path }.size).to eq(1)
      expect(response).to have_http_status(:ok)
      expect(pending_count_queries { get inventory_stock_transfers_path }.size).to eq(1)
      expect(pending_count_queries { get inventory_stock_transfer_approvals_path }).to be_empty # reuses its loaded rows
    end

    it "renders the queue in Arabic, right to left, without a navigation entry" do
      transfer(:pending_approval)
      user = approver
      user.update_column(:preferred_locale, "ar")
      sign_in user
      get inventory_stock_transfer_approvals_path
      expect(doc.at_css("html")["dir"]).to eq("rtl")
      expect(doc.at_css("h1").text).to include("اعتماد التحويلات")
      expect(nav_links.map { |a| a.text.squish }.join(" ")).not_to include("اعتماد التحويلات")
      expect(nav_links.map { |a| a.text.squish }.join(" ")).to include("تحويلات المخزون")
      expect(doc.css(".ws__rail a.is-active")).to be_empty
    end
  end
end
