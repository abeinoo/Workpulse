require "rails_helper"

# Quick Issue popup (Inventory::QuickIssuesController): ONE product per
# transaction, opened in the global modal (<turbo-frame id="modal">) from every
# entry point, issued from a warehouse the user is authorized to use — fixed
# when there is only one, a selector of exactly those when there are several.
RSpec.describe "Quick Issue", type: :request do
  let(:business)  { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let!(:primary)  { create(:branch, business: business, name: "Nasr City") }
  let!(:assigned) { create(:branch, business: business, name: "Maadi") }
  let!(:elsewhere) { create(:branch, business: business, name: "Zayed") }
  let!(:main)     { branch_warehouse_for(primary, name: "Main") }
  let!(:maadi_wh) { branch_warehouse_for(assigned, name: "Maadi WH") }
  let!(:zayed_wh) { branch_warehouse_for(elsewhere, name: "Zayed WH") }  # not authorized to quick_user
  let!(:central)  { business.warehouses.create!(name: "Central", kind: "central") }
  let!(:shampoo) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let!(:towels)  { business.products.create!(name: "Towels", sku: "TW-1", initial_cost_price: 4, average_cost_price: 4) }

  let(:quick_user) do
    role = business.permission_roles.create!(name: "Quick", permissions: %w[view_inventory quick_issue_stock])
    create(:user, business: business).tap do |u|
      u.update_column(:permission_role_id, role.id)
      restrict_to_warehouses!(u, main, maadi_wh) # two authorized warehouses → a selector
    end
  end

  let(:solo_user) do
    role = business.permission_roles.create!(name: "Solo", permissions: %w[view_inventory quick_issue_stock])
    create(:user, business: business).tap do |u|
      u.update_column(:permission_role_id, role.id)
      restrict_to_warehouses!(u, main) # one authorized warehouse → used automatically
    end
  end

  def receive!(warehouse, product, quantity)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: quantity, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(receipt).call
  end

  before do
    receive!(main, shampoo, 10)
    receive!(main, towels, 10)
    receive!(maadi_wh, shampoo, 3)
    receive!(zayed_wh, shampoo, 70)
    receive!(central, shampoo, 50)
  end

  # The header Turbo sends for a request made inside <turbo-frame id="modal">.
  def frame = { "Turbo-Frame" => "modal" }

  def html = Nokogiri::HTML(response.body)

  def open_popup(product = shampoo, headers: frame)
    get new_inventory_quick_issue_path(product_id: product&.id), headers: headers
  end

  def post_quick_issue(product: shampoo, quantity: "2", warehouse: main, reason: "internal_use", notes: nil, extra: {}, headers: frame)
    post inventory_quick_issue_path, headers: headers, params: { return_to: "/inventory/products", quick_issue: {
      warehouse_id: warehouse&.id, branch_id: elsewhere.id, # a branch is never an input (ignored)
      product_id: product&.id, quantity: quantity, issue_reason: reason, notes: notes
    }.merge(extra) }
  end

  def warehouse_option(name) = html.css("select[name='quick_issue[warehouse_id]'] option").find { |o| o.text == name }

  def quick_issue!(warehouse, product, quantity)
    Inventory::StockIssueQuickIssue.new(actor: owner, warehouse_id: warehouse.id, product_id: product.id, quantity: quantity,
                                        reason: "internal_use").call
  end

  describe "the single-product popup" do
    before { sign_in quick_user }

    it "renders inside the modal frame with the product, one quantity, Cancel and Confirm Issue" do
      open_popup
      expect(response).to have_http_status(:ok)
      dialog = html.at_css("turbo-frame#modal [data-testid='quick-issue-dialog']")
      expect(dialog).to be_present
      expect(dialog.at_css("[data-testid='quick-issue-product']").text).to include("Shampoo", "SH-1")
      expect(dialog.css("input[name='quick_issue[product_id]']").map { |i| i["value"] }).to eq([ shampoo.id.to_s ])
      expect(dialog.css("input[name='quick_issue[quantity]']").size).to eq(1)
      expect(dialog.at_css("[data-testid='quick-issue-cancel']")["data-action"]).to eq("click->modal#close")
      expect(dialog.at_css("[data-testid='quick-issue-submit']").text).to include(I18n.t("inventory.quick_issue.confirm"))
    end

    it "has Notes as its only free-text field — no Description — optional until Other is chosen" do
      open_popup
      expect(html.css("[name='quick_issue[issue_reason_note]']")).to be_empty
      expect(html.css("textarea, input[type='text']").map { |f| f["name"] }).to eq([ "quick_issue[notes]" ])
      expect(html.at_css("textarea[name='quick_issue[notes]']")["required"]).to be_nil
      expect(html.at_css("[data-testid='quick-issue-notes-hint']").text.strip).to eq(I18n.t("inventory.quick_issue.notes_hint"))
    end

    it "has no product-line management: no line rows, no Add Product, no items_attributes" do
      open_popup
      expect(response.body).not_to include("items_attributes", "line-items", "data-line-row")
      expect(html.css("[data-action*='line-items#add']")).to be_empty
    end

    it "with several authorized warehouses: a selector of exactly those, each carrying its available quantity" do
      open_popup
      names = html.css("select[name='quick_issue[warehouse_id]'] option").select { |o| o["value"].present? }.map(&:text)
      expect(names).to contain_exactly("Main", "Maadi WH")
      expect(warehouse_option("Main")["data-available"]).to eq("10.0")
      expect(warehouse_option("Maadi WH")["data-available"]).to eq("3.0")
      expect(response.body).not_to include("Zayed WH", "Central")
      expect(html.css("[name*='branch']")).to be_empty # no consuming branch field
      expect(html.at_css("[data-testid='quick-issue-availability']").has_attribute?("hidden")).to be(true) # until one is chosen
      expect(html.at_css("[data-testid='quick-issue-submit']")["disabled"]).to be_present
    end

    it "with exactly one authorized warehouse: shown, not selectable, and its availability visible before any quantity" do
      sign_in solo_user
      open_popup
      expect(html.css("select[name='quick_issue[warehouse_id]']")).to be_empty
      expect(html.at_css("[data-testid='quick-issue-warehouse-name']").text).to eq("Main")
      expect(html.at_css("input[type='hidden'][name='quick_issue[warehouse_id]']")["value"]).to eq(main.id.to_s)
      expect(html.at_css("input[name='quick_issue[quantity]']")["value"]).to be_blank
      availability = html.at_css("[data-testid='quick-issue-availability']")
      expect(availability["hidden"]).to be_nil
      expect(availability.at_css("[data-testid='quick-issue-available']").text).to include("10", I18n.t("inventory.quick_issue.units"))
      expect(availability.at_css("[data-testid='quick-issue-source']").text).to include("Main")
      expect(html.at_css("input[name='quick_issue[quantity]']")["max"]).to eq("10.0")
    end

    it "with no accessible active warehouse: explains it and offers no Confirm" do
      main.update_column(:status, "inactive")
      sign_in solo_user
      open_popup
      expect(html.at_css("[data-testid='quick-issue-no-warehouse']").text)
        .to eq(I18n.t("inventory.issue_warehouse.errors.none_accessible"))
      expect(html.at_css("[data-testid='quick-issue-submit']")["disabled"]).to be_present
    end

    it "excludes stock reserved by approved issues from the figure" do
      reserved = business.stock_issues.build(warehouse: main, issued_on: Date.current)
      reserved.items.build(product: shampoo, quantity: 4)
      save_stock_issue_in_status!(reserved, :approved)

      open_popup
      expect(warehouse_option("Main")["data-available"]).to eq("6.0")
    end

    it "blocks Confirm when the only warehouse has nothing available" do
      sign_in solo_user
      open_popup(towels)
      expect(html.at_css("[data-testid='quick-issue-submit']")["disabled"]).to be_nil
      quick_issue!(main, towels, "10")
      open_popup(towels)
      expect(html.at_css("[data-testid='quick-issue-available']").text).to include("0")
      expect(html.at_css("[data-testid='quick-issue-submit']")["disabled"]).to be_present
    end

    it "offers the five reasons" do
      open_popup
      values = html.css("select[name='quick_issue[issue_reason]'] option").map { |o| o["value"] }.compact_blank
      expect(values).to eq(%w[internal_use damaged expired lost other])
    end

    it "opens the compact product step when there is no product, choosing one opens the popup" do
      open_popup(nil)
      step = html.at_css("turbo-frame#modal [data-testid='quick-issue-product-step']")
      expect(step).to be_present
      expect(step.at_css("form")["method"]).to eq("get")
      expect(step.at_css("input[name='step']")["value"]).to eq("1")
      expect(step.css("select[name='product_id']").size).to eq(1)
      expect(html.css("[data-testid='quick-issue-dialog']")).to be_empty
    end

    it "stays tied to the requested product: an unusable one shows an error, never a picker for another product" do
      archived = business.products.create!(name: "Old", sku: "OLD-1", initial_cost_price: 1, average_cost_price: 1, active: false)
      open_popup(archived)
      expect(html.at_css("[data-testid='quick-issue-unavailable'] [data-testid='quick-issue-error']").text.strip)
        .to eq(I18n.t("inventory.quick_issue.errors.product_unavailable"))
      expect(html.css("[data-testid='quick-issue-product-step'], select[name='product_id']")).to be_empty
    end

    it "offers no way to change the product inside the popup" do
      open_popup
      expect(html.css("[data-testid='quick-issue-change-product']")).to be_empty
      expect(html.css("a[href^='#{new_inventory_quick_issue_path}']")).to be_empty
      expect(html.css("select[name='product_id'], [data-controller='product-combobox']")).to be_empty
      expect(html.at_css("[data-testid='quick-issue-product']").text).to include("Shampoo", "SH-1")
    end

    it "asks the modal to center it" do
      open_popup
      expect(html.at_css("[data-testid='quick-issue-dialog']")["data-modal-placement"]).to eq("center")
    end

    it "re-offers the picker only from the product step itself (an invalid choice there)" do
      get new_inventory_quick_issue_path(product_id: 0, step: 1), headers: frame
      expect(html.at_css("[data-testid='quick-issue-product-step'] [data-testid='quick-issue-product-error']")).to be_present
    end

    it "renders as a compact page (one modal frame only — the layout's) when opened outside the modal" do
      open_popup(shampoo, headers: {})
      expect(html.at_css("[data-testid='quick-issue-page'] [data-testid='quick-issue-dialog']")).to be_present
      expect(html.css("turbo-frame#modal").size).to eq(1)
      expect(html.at_css("[data-testid='quick-issue-cancel']").name).to eq("a")
    end
  end

  describe "posting from the popup" do
    before { sign_in quick_user }

    it "posts exactly one product from the selected warehouse, then sends the browser back to the opening page" do
      expect { post_quick_issue(quantity: "2.5") }.to change(StockIssue, :count).by(1).and change(StockIssueItem, :count).by(1)

      issue = StockIssue.order(:id).last
      expect(issue).to be_issued
      expect(issue).to be_quick_issue
      expect(issue.warehouse).to eq(main)
      expect(issue.branch_id).to eq(primary.id) # cost attribution from Main — the submitted branch was ignored
      expect(InventoryMovement.where(reason: "stock_issue").pluck(:warehouse_id)).to eq([ main.id ])
      expect(issue.items.map { |i| [ i.product_id, i.quantity.to_d ] }).to eq([ [ shampoo.id, BigDecimal("2.5") ] ])

      # quick_issue_stock alone does not include viewing Stock Issues: back to the page it was opened from.
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      stream = html.at_css("turbo-stream[action='visit']")
      expect(stream["url"]).to eq("/inventory/products")
      expect(flash[:notice]).to eq(I18n.t("inventory.quick_issue.success", number: issue.issue_number, product: "Shampoo"))
    end

    it "opens the posted issue, with its reason, for someone who may view Stock Issues" do
      quick_user.permission_role.update!(permissions: %w[view_inventory quick_issue_stock view_stock_issues])
      post_quick_issue(reason: "damaged")
      issue = StockIssue.order(:id).last
      expect(html.at_css("turbo-stream[action='visit']")["url"]).to eq(inventory_stock_issue_path(issue))

      get inventory_stock_issue_path(issue)
      expect(html.at_css("[data-testid='stock-issue-reason']").text).to include(I18n.t("inventory.stock_issues.reasons.damaged"))
    end

    it "redirects normally when posted from the compact page" do
      post_quick_issue(headers: {})
      expect(response).to redirect_to("/inventory/products")
    end

    it "writes the four mandatory audit entries" do
      post_quick_issue
      expect(AuditLog.for_auditable(StockIssue.order(:id).last).order(:id).map(&:action))
        .to eq(%w[create submit_for_approval approve confirm])
    end

    describe "one product per transaction" do
      it "refuses the old multi-line items_attributes shape and posts nothing" do
        lines = { items_attributes: { "0" => { product_id: shampoo.id, quantity: "1" }, "1" => { product_id: towels.id, quantity: "1" } } }
        expect { post_quick_issue(product: nil, quantity: nil, extra: lines) }
          .to not_change(StockIssue, :count).and not_change(InventoryMovement, :count).and not_change(AuditLog, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include(CGI.escapeHTML(I18n.t("inventory.quick_issue.errors.single_product_only")))
      end

      it "refuses a repeated product_id[] / quantity[]" do
        post inventory_quick_issue_path, headers: frame, params: { quick_issue: {
          product_id: [ shampoo.id, towels.id ], quantity: [ "1", "1" ], warehouse_id: main.id, issue_reason: "internal_use"
        } }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(StockIssue.count).to eq(0)
        expect(response.body).to include(CGI.escapeHTML(I18n.t("inventory.quick_issue.errors.single_product_only")))
      end
    end

    describe "validation inside the popup (product and values kept)" do
      [ "0", "-1", "abc", "1.2345" ].each do |bad|
        it "refuses the quantity #{bad.inspect}" do
          expect { post_quick_issue(quantity: bad, reason: "other", notes: "Display") }.not_to change(StockIssue, :count)
          expect(response).to have_http_status(:unprocessable_entity)
          dialog = html.at_css("turbo-frame#modal [data-testid='quick-issue-dialog']")
          expect(dialog.at_css("[data-testid='quick-issue-quantity-error']").text)
            .to eq(I18n.t("inventory.quick_issue.errors.quantity_invalid"))
          expect(dialog.at_css("input[name='quick_issue[product_id]']")["value"]).to eq(shampoo.id.to_s)
          expect(dialog.at_css("input[name='quick_issue[quantity]']")["value"]).to eq(bad)
          expect(dialog.at_css("select[name='quick_issue[issue_reason]'] option[selected]")["value"]).to eq("other")
          expect(dialog.at_css("textarea[name='quick_issue[notes]']").text.strip).to eq("Display")
        end
      end

      it "refuses more than the selected warehouse holds, beside the quantity, and posts nothing" do
        expect { post_quick_issue(quantity: "11") }
          .to not_change(StockIssue, :count).and not_change(InventoryMovement, :count).and not_change(AuditLog, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        error = html.at_css("[data-testid='quick-issue-quantity-error']").text
        expect(error).to include("Shampoo", "Main", "10", "11")
        expect(html.at_css("[data-testid='quick-issue-available']").text).to include("10")
      end

      it "re-checks availability on submission (stock taken after the popup opened)" do
        open_popup
        expect(warehouse_option("Main")["data-available"]).to eq("10.0")
        quick_issue!(main, shampoo, "9")

        expect { post_quick_issue(quantity: "2") }.not_to change(StockIssue, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(html.at_css("[data-testid='quick-issue-quantity-error']").text).to include("1")
      end

      it "refuses a tampered, unauthorized or inactive warehouse beside the warehouse field — never another one instead" do
        [ zayed_wh, central ].each do |warehouse|
          expect { post_quick_issue(warehouse: warehouse) }.not_to change(StockIssue, :count)
          expect(response).to have_http_status(:unprocessable_entity)
          expect(html.at_css("[data-testid='quick-issue-warehouse-error']").text)
            .to eq(I18n.t("inventory.issue_warehouse.errors.not_allowed"))
        end
        maadi_wh.update_column(:status, "inactive")
        expect { post_quick_issue(warehouse: maadi_wh) }.not_to change(StockIssue, :count)
        expect(InventoryMovement.where(reason: "stock_issue")).to be_empty
      end

      it "requires a warehouse choice when several are authorized" do
        expect { post_quick_issue(warehouse: nil) }.not_to change(StockIssue, :count)
        expect(html.at_css("[data-testid='quick-issue-warehouse-error']").text)
          .to eq(I18n.t("inventory.issue_warehouse.errors.required"))
      end

      it "uses the only authorized warehouse without a submitted one" do
        sign_in solo_user
        expect { post_quick_issue(warehouse: nil) }.to change(StockIssue, :count).by(1)
        expect(StockIssue.order(:id).last.warehouse).to eq(main)
      end

      it "requires Notes for Other — beside the Notes field — and records them as the reason" do
        expect { post_quick_issue(reason: "other") }.not_to change(StockIssue, :count)
        expect(html.at_css("[data-testid='quick-issue-notes-error']").text)
          .to eq(I18n.t("inventory.quick_issue.errors.notes_required_for_other"))
        expect(html.at_css("textarea[name='quick_issue[notes]']")["required"]).to be_present
        expect(html.at_css("[data-testid='quick-issue-notes-hint']").text.strip).to eq(I18n.t("inventory.quick_issue.notes_other_hint"))

        post_quick_issue(reason: "other", notes: "Display sample")
        expect(StockIssue.order(:id).last).to have_attributes(issue_reason: "other", notes: "Display sample",
                                                              issue_reason_note: "Display sample")
      end

      it "shows an Other reason's text once on the issue page (with the reason, not repeated as Notes)" do
        quick_user.permission_role.update!(permissions: %w[view_inventory quick_issue_stock view_stock_issues])
        post_quick_issue(reason: "other", notes: "Display sample")
        get inventory_stock_issue_path(StockIssue.order(:id).last)
        expect(html.at_css("[data-testid='stock-issue-reason']").text).to include("Display sample")
        expect(html.css("[data-testid='stock-issue-notes']")).to be_empty
      end

      it "keeps Notes optional for the other reasons" do
        expect { post_quick_issue(reason: "damaged") }.to change(StockIssue, :count).by(1)
        expect(StockIssue.order(:id).last).to have_attributes(notes: nil, issue_reason_note: nil)
      end
    end
  end

  describe "access" do
    it "works with quick_issue_stock alone — no view_inventory — including the product picker" do
      role = business.permission_roles.create!(name: "Quick only", permissions: %w[quick_issue_stock])
      only = create(:user, business: business).tap do |u|
        u.update_column(:permission_role_id, role.id)
        restrict_to_warehouses!(u, main)
      end
      sign_in only

      open_popup
      expect(response).to have_http_status(:ok)
      get inventory_product_search_path(q: "Sham")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.map { |p| p["id"] }).to include(shampoo.id)
      get inventory_products_path
      expect(response).to redirect_to(root_path).or have_http_status(:forbidden) # no catalogue pages
    end

    it "is refused without quick_issue_stock, even with create + approve + confirm" do
      sign_in stock_issue_user(business, :create_stock_issues, :approve_stock_issues, :confirm_stock_issues)
      open_popup
      expect(response).to redirect_to(root_path).or have_http_status(:forbidden)
      post_quick_issue
      expect(StockIssue.count).to eq(0)
    end

    it "is refused to employees but available to the owner (any active warehouse) when the company setting is disabled" do
      OrganizationAccess::StockIssueWorkflowSettings.call(business: business, actor: owner, self_approval: "forbidden",
                                                          quick_issue_enabled: false)
      sign_in quick_user
      open_popup
      expect(response).to redirect_to(root_path).or have_http_status(:forbidden)

      sign_in owner
      open_popup
      expect(response).to have_http_status(:ok)
      expect(warehouse_option("Zayed WH")["data-available"]).to eq("70.0")
      expect(warehouse_option("Central")["data-available"]).to eq("50.0")
      expect { post_quick_issue(warehouse: zayed_wh, quantity: "5") }.to change(StockIssue, :count).by(1)
      expect(StockIssue.order(:id).last.warehouse).to eq(zayed_wh)
    end

    it "stays usable when the Standard Stock Issue forbids self-approval" do
      OrganizationAccess::StockIssueWorkflowSettings.call(business: business, actor: owner, self_approval: "forbidden",
                                                          quick_issue_enabled: true)
      sign_in quick_user
      expect { post_quick_issue }.to change(StockIssue, :count).by(1)
    end
  end

  describe "historical Quick Issues" do
    it "still show every line they were posted with" do
      issue = business.stock_issues.build(warehouse: main, branch: primary, issued_on: Date.current - 2, created_by: owner,
                                          workflow: "quick_issue", issue_reason: "lost", warehouse_source: "branch_warehouse",
                                          status: "issued")
      issue.items.build(product: shampoo, quantity: 1)
      issue.items.build(product: towels, quantity: 1)
      issue.save!(validate: false)

      sign_in owner
      get inventory_stock_issue_path(issue)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Shampoo", "Towels")
      expect(issue.reload.items.count).to eq(2)
    end
  end

  describe "entry points — all open the popup in the modal frame" do
    before { sign_in owner }

    it "is offered in each Products index row menu — opening the popup — but not in the header or the workspace navigation" do
      get inventory_products_path
      expect(response).to have_http_status(:ok)
      row = html.at_css("[data-testid='product-quick-issue']")
      expect(row["href"]).to match(%r{\A#{Regexp.escape(new_inventory_quick_issue_path)}\?product_id=\d+\z})
      expect(row["data-turbo-frame"]).to eq("modal")
      expect(html.css("[data-testid='products-quick-issue']")).to be_empty # no header button
      expect(html.css("a.ws__rail-item, a.ws__more-item, a.ws__tab").map { |a| a["href"] }).not_to include(new_inventory_quick_issue_path)
    end

    it "opens the popup from the product row's link" do
      get inventory_products_path
      href = html.at_css("[data-testid='product-quick-issue']")["href"]
      get href, headers: frame
      expect(html.at_css("turbo-frame#modal [data-testid='quick-issue-dialog']")).to be_present
    end

    it "links from the product page, the Stock Issues header and the dashboard" do
      get inventory_product_path(shampoo)
      link = html.at_css("[data-testid='product-quick-issue']")
      expect([ link["href"], link["data-turbo-frame"] ]).to eq([ new_inventory_quick_issue_path(product_id: shampoo.id), "modal" ])

      get inventory_stock_issues_path
      expect(html.at_css("[data-testid='stock-issues-quick-issue']")["data-turbo-frame"]).to eq("modal")

      get inventory_root_path
      expect(html.at_css("[data-testid='dashboard-quick-issue']")["data-turbo-frame"]).to eq("modal")
    end

    it "opens the popup from the product page's link" do
      get inventory_product_path(shampoo)
      href = html.at_css("[data-testid='product-quick-issue']")["href"]
      get href, headers: frame
      expect(html.at_css("turbo-frame#modal [data-testid='quick-issue-dialog']")).to be_present
    end
  end
end
