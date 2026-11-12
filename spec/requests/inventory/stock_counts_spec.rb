require "rails_helper"

RSpec.describe "Inventory::StockCounts", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  let(:counter) do  # can create sessions and edit counts, but NOT approve
    role = business.permission_roles.create!(name: "Counter", permissions: %w[view_inventory manage_stock_counts])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:approver) do # can approve
    role = business.permission_roles.create!(name: "Approver", permissions: %w[view_inventory post_stock_counts])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", barcode: "111", initial_cost_price: 10, average_cost_price: 10)
  end

  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 20, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def start_session(as:)
    sign_in as
    post inventory_stock_counts_path, params: {
      stock_count: { warehouse_id: warehouse.id, counted_on: Date.current }
    }
    business.stock_counts.order(:id).last
  end

  def set_count(count, qty, as:)
    sign_in as
    item = count.items.first
    patch inventory_stock_count_path(count), params: {
      stock_count: { items_attributes: { "0" => { id: item.id, product_id: product.id, counted_quantity: qty } } }
    }
    count.reload
  end

  describe "session creation" do
    it "renders index and new" do
      sign_in owner
      get inventory_stock_counts_path
      expect(response).to have_http_status(:ok)
      get new_inventory_stock_count_path
      expect(response).to have_http_status(:ok)
    end

    it "preloads a row per product with snapshotted system quantity (status draft)" do
      count = start_session(as: counter)
      expect(count).to be_draft
      expect(count.items.size).to eq(business.products.count)
      expect(count.items.find_by(product: product).system_quantity).to eq(20)
    end

    it "renders the counting screen with the scanner, progress and filters" do
      count = start_session(as: counter)
      sign_in counter
      get edit_inventory_stock_count_path(count)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="line-items count-sheet"')
      expect(response.body).to include('data-barcode-scanner-mode-value="rows"')
      expect(response.body).to include('data-count-sheet-target="progressBar"')
      expect(response.body).to include('data-filter="not_counted"')
    end
  end

  describe "counting → completion → approval" do
    it "moves to in_progress on the first saved count and computes the difference" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      expect(count).to be_in_progress
      item = count.items.first
      expect(item.system_quantity).to eq(20)
      expect(item.difference).to eq(-3)
    end

    it "counter completes, approver approves → adjustment corrects stock" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)

      sign_in counter
      patch complete_inventory_stock_count_path(count)
      expect(count.reload).to be_completed

      sign_in approver
      patch approve_inventory_stock_count_path(count)
      expect(response).to redirect_to(inventory_stock_count_path(count))
      expect(count.reload).to be_approved
      expect(product.reload.current_stock).to eq(17)
      expect(count.active_stock_adjustment).to be_present
      expect(count.active_stock_adjustment.reason).to eq("stock_count")
    end

    it "lets an approver send a completed count back (reopen)" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      sign_in counter
      patch complete_inventory_stock_count_path(count)

      sign_in approver
      patch reopen_inventory_stock_count_path(count)
      expect(count.reload).to be_in_progress
    end
  end

  describe "segregation of duties (employees cannot approve)" do
    it "forbids a counter from approving a completed count" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      sign_in counter
      patch complete_inventory_stock_count_path(count)

      patch approve_inventory_stock_count_path(count)   # counter lacks post_stock_counts
      expect(response).to redirect_to(root_path)
      expect(count.reload).to be_completed
    end

    it "cannot approve before completion" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)   # in_progress, not completed
      sign_in approver
      patch approve_inventory_stock_count_path(count)
      expect(response).to redirect_to(root_path)
      expect(count.reload).to be_in_progress
    end

    it "forbids editing an approved count" do
      count = start_session(as: owner)
      set_count(count, 17, as: owner)
      sign_in owner
      patch complete_inventory_stock_count_path(count)
      patch approve_inventory_stock_count_path(count)

      set_count(count, 5, as: owner)
      expect(count.reload.items.first.counted_quantity).to eq(17)
    end
  end

  describe "approval with uncounted products" do
    let!(:other) { business.products.create!(name: "Conditioner", sku: "CN-1", initial_cost_price: 4, average_cost_price: 4) }

    before do  # give "other" real stock so we'd notice if approval touched it
      r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      r.items.build(product: other, quantity: 9, unit_cost: 4)
      Inventory::GoodsReceiptPoster.new(r).call
    end

    it "approves, skipping uncounted products without affecting their stock" do
      count = start_session(as: counter)                  # preloads product + other (both blank)
      item  = count.items.find_by(product: product)
      sign_in counter
      patch inventory_stock_count_path(count), params: {  # count only one of the two products
        stock_count: { items_attributes: { "0" => { id: item.id, product_id: product.id, counted_quantity: 17 } } }
      }
      patch complete_inventory_stock_count_path(count)
      expect(count.reload).to be_completed

      sign_in approver
      patch approve_inventory_stock_count_path(count)
      expect(count.reload).to be_approved
      expect(product.reload.current_stock).to eq(17)      # counted product corrected
      expect(other.reload.current_stock).to eq(9)         # uncounted product untouched
      # no adjustment line for the uncounted product
      expect(count.active_stock_adjustment.items.map(&:product)).to eq([ product ])
    end
  end

  describe "CSV export" do
    it "exports product, barcode, sku, system, counted and difference" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)

      sign_in counter
      get export_inventory_stock_count_path(count, format: :csv)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      expect(response.body).to include("Product,Barcode,SKU,System Quantity,Counted Quantity,Difference")
      expect(response.body).to include("Shampoo,111,SH-1,20,17,-3")
    end
  end

  describe "report figures" do
    it "summarises matched / shortage / overage counts and adjustment value" do
      other = business.products.create!(name: "Conditioner", sku: "CN-1", initial_cost_price: 4, average_cost_price: 4)
      count = start_session(as: counter)
      count.items.find_by(product: product).update!(counted_quantity: 17)  # -3 shortage
      count.items.find_by(product: other).update!(counted_quantity: 2)     # +2 overage (system 0)

      expect(count.shortage_count).to eq(1)
      expect(count.overage_count).to eq(1)
      expect(count.matched_count).to eq(0)
      # (-3 * 10) + (2 * 4) = -22
      expect(count.adjustment_value).to eq(-22)
    end
  end

  describe "count ⇄ adjustment navigation" do
    it "links between the approved count and its generated adjustment, both ways" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      sign_in counter
      patch complete_inventory_stock_count_path(count)
      sign_in approver
      patch approve_inventory_stock_count_path(count)
      adj = count.reload.active_stock_adjustment
      expect(adj).to be_present

      # Adjustment → source count
      get inventory_stock_adjustment_path(adj)
      expect(response.body).to include(count.count_number)
      expect(response.body).to include(inventory_stock_count_path(count))

      # Count → adjustment, plus the value-impact section
      get inventory_stock_count_path(count)
      expect(response.body).to include(adj.adjustment_number)
      expect(response.body).to include(inventory_stock_adjustment_path(adj))
      expect(response.body).to include(I18n.t("inventory.stock_counts.impact.title"))
    end
  end

  describe "lifecycle repair (D1–D9) over HTTP" do
    # Submits the counting form exactly as the page rendered it (every input
    # the browser would send), optionally changing some rows' quantities.
    def submit_sheet_as_rendered(count, changes = {})
      get edit_inventory_stock_count_path(count)
      form = Nokogiri::HTML(response.body).at_css("form[data-controller~='count-sheet']")
      params = form.css("input[name^='stock_count[']").each_with_object({}) do |input, acc|
        acc[input["name"]] = input["value"].to_s
      end
      changes.each do |product, quantity|
        row   = form.css("tr[data-line-row]").find { |tr| tr["data-product-id"] == product.id.to_s }
        field = row.at_css("input[data-quantity-field]")["name"]
        params[field] = quantity.to_s
      end
      patch inventory_stock_count_path(count), params: Rack::Utils.parse_nested_query(params.to_query)
      expect(response).to redirect_to(inventory_stock_count_path(count))
    end

    describe "resuming a count (last entered quantities)" do
      let!(:serum) do
        business.products.create!(name: "Serum", sku: "GKM-84978", initial_cost_price: 50, average_cost_price: 50).tap do |p|
          r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
          r.items.build(product: p, quantity: BigDecimal("4.004"), unit_cost: 50)
          Inventory::GoodsReceiptPoster.new(r).call
        end
      end

      def physical_count_with_serum(quantity)
        count = start_session(as: counter)
        sign_in counter
        item = count.items.find_by!(product: serum)
        patch inventory_stock_count_path(count), params: {
          stock_count: { items_attributes: { "0" => { id: item.id, product_id: serum.id, counted_quantity: quantity } } }
        }
        [ count.reload, item.reload ]
      end

      def serum_input(count)
        get edit_inventory_stock_count_path(count)
        Nokogiri::HTML(response.body).css("tr[data-line-row]").find { |tr| tr["data-sku"] == "GKM-84978" }
                                     .at_css("input[data-quantity-field]")["value"]
      end

      it "shows a saved physical quantity of 3, not the 4.004 system stock, on every return to the sheet" do
        count, item = physical_count_with_serum(3)
        expect(item).to have_attributes(quantity_source: "physical", system_quantity: BigDecimal("4.004"))

        expect(serum_input(count)).to eq("3")
        get inventory_stock_count_path(count)                 # navigate away …
        expect(serum_input(count)).to eq("3")                 # … and back / refresh
      end

      it "does not change the quantity, source or timestamp by opening or re-saving the sheet" do
        count, item = physical_count_with_serum(3)
        before = item.attributes.slice("counted_quantity", "quantity_source", "counted_at", "baseline_at", "system_quantity", "difference")

        travel_to(1.hour.from_now) do
          serum_input(count)
          submit_sheet_as_rendered(count)
        end
        expect(item.reload.attributes.slice(*before.keys)).to eq(before)
        expect(AuditLog.for_auditable(count).where(action: "record_counts").count).to eq(1)   # no new recount
      end

      it "records a new physical recount only when the quantity is changed and saved" do
        count, item = physical_count_with_serum(3)
        first_counted_at = item.counted_at
        receive_more = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
        receive_more.items.build(product: serum, quantity: 2, unit_cost: 50)
        Inventory::GoodsReceiptPoster.new(receive_more).call            # serum now 6.004

        travel_to(1.hour.from_now) { submit_sheet_as_rendered(count, serum => 5) }
        expect(item.reload).to have_attributes(counted_quantity: 5, quantity_source: "physical",
                                               system_quantity: BigDecimal("6.004"), difference: BigDecimal("-1.004"))
        expect(item.counted_at).to be > first_counted_at
        expect(serum_input(count)).to eq("5")
      end

      it "leaves rows that were never counted blank and uncounted" do
        count, = physical_count_with_serum(3)
        submit_sheet_as_rendered(count)
        other = count.items.find_by!(product: product)
        expect(other).to have_attributes(counted_quantity: nil, quantity_source: nil)
      end
    end

    def complete_as(count, user)
      sign_in user
      patch complete_inventory_stock_count_path(count)
      count.reload
    end

    def approve_as(count, user)
      sign_in user
      patch approve_inventory_stock_count_path(count)
      count.reload
    end

    def approved_count
      count = start_session(as: counter)
      set_count(count, 17, as: counter)          # −3
      complete_as(count, counter)
      approve_as(count, approver)
    end

    it "explains on the page that completing does not change inventory" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      complete_as(count, counter)
      expect(product.reload.current_stock).to eq(20)

      get inventory_stock_count_path(count)
      expect(response.body).to include(I18n.t("inventory.stock_counts.statuses.completed"))
      expect(response.body).to include(I18n.t("inventory.stock_counts.guidance.awaiting_approval"))
      expect(response.body).to include(I18n.t("inventory.stock_counts.guidance.self_approval_blocked"))
    end

    it "lets the owner approve their own count, with the exception shown and audited" do
      count = start_session(as: owner)
      set_count(count, 17, as: owner)
      complete_as(count, owner)
      get inventory_stock_count_path(count)
      expect(response.body).to include(I18n.t("inventory.stock_counts.owner_self_approval_badge"))

      approve_as(count, owner)
      expect(count).to be_approved
      expect(product.reload.current_stock).to eq(17)
      expect(AuditLog.for_auditable(count).find_by(action: "approve").metadata["owner_self_approval"]).to be(true)
    end

    it "reopens an approved count with a reason, reversing its adjustment" do
      count = approved_count
      adjustment = count.active_stock_adjustment

      sign_in approver
      get inventory_stock_count_path(count)
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("inventory.stock_counts.reopen_approved_action")))
      patch reopen_inventory_stock_count_path(count), params: { reason: "Shelf B missed" }

      expect(response).to redirect_to(inventory_stock_count_path(count))
      expect(count.reload).to be_in_progress
      expect(adjustment.reload).to be_voided
      expect(product.reload.current_stock).to eq(20)
    end

    it "refuses to reopen an approved count without a reason" do
      count = approved_count
      sign_in approver
      patch reopen_inventory_stock_count_path(count), params: { reason: "" }
      expect(flash[:alert]).to eq(I18n.t("inventory.stock_counts.errors.reopen_reason_required"))
      expect(count.reload).to be_approved
    end

    it "forbids a counter from reopening an approved count" do
      count = approved_count
      sign_in counter
      patch reopen_inventory_stock_count_path(count), params: { reason: "x" }
      expect(response).to redirect_to(root_path)
      expect(count.reload).to be_approved
    end

    it "deletes an unposted count with a reason and confirmation, audited" do
      count = start_session(as: counter)
      sign_in counter
      get inventory_stock_count_path(count)
      expect(response.body).to include(I18n.t("inventory.stock_counts.delete_confirm"))

      delete inventory_stock_count_path(count), params: { reason: "Wrong warehouse" }
      expect(response).to redirect_to(inventory_stock_counts_path)
      expect(StockCount.exists?(count.id)).to be(false)
      expect(AuditLog.where(auditable_type: "StockCount", auditable_id: count.id, action: "delete")).to exist
    end

    it "never answers a refused delete with a 500" do
      count = start_session(as: counter)
      set_count(count, 17, as: counter)
      complete_as(count, counter)

      sign_in counter
      delete inventory_stock_count_path(count), params: { reason: "x" }   # completed: policy refuses
      expect(response).to redirect_to(root_path)
      expect(StockCount.exists?(count.id)).to be(true)

      in_progress = start_session(as: counter)
      delete inventory_stock_count_path(in_progress), params: { reason: "" }   # allowed, but no reason
      expect(response).to redirect_to(inventory_stock_count_path(in_progress))
      expect(flash[:alert]).to eq(I18n.t("inventory.stock_counts.errors.removal_reason_required"))
    end

    it "cancels (never deletes) a reopened count that posted stock" do
      count = approved_count
      sign_in approver
      patch reopen_inventory_stock_count_path(count), params: { reason: "recount" }

      sign_in counter
      get inventory_stock_count_path(count)
      expect(response.body).to include(I18n.t("inventory.stock_counts.cancel_action"))
      expect(response.body).not_to include(I18n.t("inventory.stock_counts.delete_action"))

      patch cancel_inventory_stock_count_path(count), params: { reason: "Superseded" }
      expect(count.reload).to be_cancelled
      expect(count.stock_adjustments.count).to eq(1)
      get inventory_stock_count_path(count)
      expect(response.body).to include(I18n.t("inventory.stock_counts.statuses.cancelled"))
      expect(response.body).to include(I18n.t("inventory.stock_counts.history.adjustments_title"))
    end

    it "blocks voiding a count's adjustment from the adjustment page" do
      count = approved_count
      adjustment = count.active_stock_adjustment
      sign_in owner
      patch void_inventory_stock_adjustment_path(adjustment), params: { void_reason: "x" }
      expect(response).to redirect_to(root_path)
      expect(adjustment.reload).not_to be_voided
    end

    it "pre-fills a legacy quantity and keeps it unverified when the sheet is saved unchanged" do
      count = start_session(as: counter)
      item  = count.items.first
      item.update!(counted_quantity: 8)                     # pre-upgrade style: no source, no time
      count.update_column(:status, "in_progress")

      sign_in counter
      get edit_inventory_stock_count_path(count)
      expect(response.body).to include(I18n.t("inventory.stock_counts.sources.legacy_hint"))
      input = Nokogiri::HTML(response.body).at_css("input[name='stock_count[items_attributes][0][counted_quantity]']")
      expect(input["value"]).to eq("8")

      submit_sheet_as_rendered(count)
      expect(item.reload).to have_attributes(counted_quantity: 8, quantity_source: nil, counted_at: nil)
      get inventory_stock_count_path(count)
      expect(response.body).to include(I18n.t("inventory.stock_counts.sources.legacy"))
    end

    it "shows the legacy-quantity banner on an editable count but not on a historical approved one" do
      count = start_session(as: counter)
      count.items.first.update!(counted_quantity: 8)        # pre-upgrade style
      count.update_column(:status, "in_progress")
      banner = I18n.t("inventory.stock_counts.guidance.legacy_editable", count: 1)

      sign_in counter
      get inventory_stock_count_path(count)
      expect(response.body).to include(ERB::Util.html_escape(banner))

      count.update_columns(status: "approved", approved_at: 1.day.ago)
      get inventory_stock_count_path(count)
      expect(response.body).not_to include(ERB::Util.html_escape(banner))
      expect(response.body).to include(I18n.t("inventory.stock_counts.sources.legacy"))   # row label stays
    end

    describe "fractional ledger quantities (SC-000008 regression)" do
      let!(:serum) do
        business.products.create!(name: "Serum", sku: "GKM-84978", initial_cost_price: 50, average_cost_price: 50).tap do |p|
          r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
          r.items.build(product: p, quantity: BigDecimal("4.004"), unit_cost: 50)
          Inventory::GoodsReceiptPoster.new(r).call
        end
      end

      # A pre-repair in-progress count holding unverified quantities.
      def legacy_in_progress_count
        count = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: counter, status: :in_progress)
        count.items.build(product: product, system_quantity: 20, counted_quantity: 18)
        count.items.build(product: serum, system_quantity: 4, counted_quantity: 3)
        count.save!
        count
      end

      it "completes over HTTP and shows 4.004 exactly, marked as a system quantity" do
        count = legacy_in_progress_count
        complete_as(count, counter)
        expect(count).to be_completed
        expect(flash[:alert]).to be_nil

        get inventory_stock_count_path(count)
        row = Nokogiri::HTML(response.body).css("tr").find { |tr| tr.text.include?("GKM-84978") }
        cells = row.css("td").map { |td| td.text.squish }
        expect(cells[2..4]).to eq([ "4.004", "4.004", "0" ])
        expect(cells[5]).to include(I18n.t("inventory.stock_counts.sources.system"))
      end

      it "after a reopen, pre-fills the last entered quantity and keeps the row system-derived when saved unchanged" do
        count = legacy_in_progress_count
        complete_as(count, counter)
        sign_in approver
        patch reopen_inventory_stock_count_path(count)

        sign_in counter
        get edit_inventory_stock_count_path(count)
        doc  = Nokogiri::HTML(response.body)
        row  = doc.css("tr[data-line-row]").find { |tr| tr["data-sku"] == "GKM-84978" }
        expect(row["data-system-quantity"]).to eq("4.004")
        expect(row.css("td")[2].text.squish).to eq("4.004")
        expect(row.at_css("input[data-quantity-field]")["value"]).to eq("3")          # the person's entry, not 4.004
        expect(row.text).to include(I18n.t("inventory.stock_counts.sources.system_hint", quantity: "4.004"))

        item   = count.items.find_by!(product: serum)
        before = item.attributes.slice("quantity_source", "counted_quantity", "system_quantity", "baseline_at", "counted_at", "difference")
        submit_sheet_as_rendered(count)
        expect(item.reload.attributes.slice(*before.keys)).to eq(before)
        expect(item).to have_attributes(quantity_source: "system", counted_quantity: BigDecimal("4.004"), difference: 0)
      end

      it "names the product's SKU in a completion error" do
        count = legacy_in_progress_count
        business.products.create!(name: "Serum mini", sku: "GKM-84978-M", parent_product_id: serum.id,
                                  initial_cost_price: 50, average_cost_price: 50)
        complete_as(count, counter)
        expect(count).to be_in_progress
        expect(flash[:alert]).to start_with("GKM-84978: ")
      end
    end

    it "ignores a system quantity posted by the client" do
      count = start_session(as: counter)
      item  = count.items.first
      sign_in counter
      patch inventory_stock_count_path(count), params: {
        stock_count: { items_attributes: { "0" => { id: item.id, product_id: product.id, counted_quantity: 17, system_quantity: 999 } } }
      }
      expect(item.reload).to have_attributes(system_quantity: 20, difference: -3, quantity_source: "physical")
    end
  end
end
