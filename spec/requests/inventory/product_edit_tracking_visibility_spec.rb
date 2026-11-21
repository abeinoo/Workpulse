require "rails_helper"

# Product Edit: the "Product availability in warehouses" section is shown only
# while "Track stock quantity" is on. Turning tracking off hides it; it never
# creates, changes, deactivates or deletes a ProductWarehouseSetting, and
# turning tracking on again shows the same rows (no duplicates). The existing
# server-side refusal (stock or open documents) is unchanged.
RSpec.describe "Product Edit — availability section follows Track stock quantity", type: :request do
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let!(:central)   { business.warehouses.create!(name: "Central WH", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City", kind: "branch", branch: create(:branch, business: business)) }
  let!(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1) }
  let(:manager)    { Inventory::ProductAvailabilityManager.new(actor: owner) }

  matcher :have_attribute_named do |name|
    match { |node| node.has_attribute?(name) }
  end

  def doc = Nokogiri::HTML(response.body)
  def section = doc.at_css("section#availability")
  def settings_snapshot = ProductWarehouseSetting.order(:id).map(&:attributes)
  def save_product(tracked) = patch inventory_product_path(product), params: { product: { name: product.name, sku: product.sku, track_inventory: tracked } }

  before do
    expect(manager.save_settings(product_id: product.id, warehouse_id: central.id, low_stock_level: 8, reorder_quantity: 20)).to be_ok
    expect(manager.save_settings(product_id: product.id, warehouse_id: branch_wh.id, low_stock_level: 2, reorder_quantity: 5)).to be_ok
    expect(manager.exclude(product_id: product.id, warehouse_id: central.id, reason: "not used")).to be_ok
    stock_and_back_out!
    sign_in owner
  end

  # History without a remaining balance: tracking may be turned off.
  def stock_and_back_out!
    [ :in, :out ].each do |direction|
      InventoryMovement.create!(business: business, product: product, warehouse: branch_wh, direction: direction,
                                quantity: 3, unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
    end
  end

  describe "layout: one Inventory Tracking, Notifications & Warehouse Availability section" do
    let(:title) { I18n.t("inventory.products.section_inventory_tracking") }

    it "holds the checkbox at the top and the warehouse cards directly below it, with no separate availability card" do
      get edit_inventory_product_path(product)
      wrapper = doc.at_css("section.form-card--split-mid")
      expect(wrapper.at_css("h2#inventory-tracking-title").text).to eq("Inventory Tracking, Notifications & Warehouse Availability")
      inner = wrapper.at_css("[data-testid='inventory-tracking-section']")
      blocks = inner.element_children
      expect(blocks.first.at_css("input[type='checkbox'][name='product[track_inventory]']")).to be_present
      expect(blocks.last["id"]).to eq("availability")
      expect(blocks.last["class"]).to include("availability-section--embedded")
      expect(blocks.last.at_css("h3#availability-title")).to be_present # a sub-heading, not a section of its own
      expect(blocks.last.css("[data-testid='availability-card-#{central.id}'], [data-testid='availability-card-#{branch_wh.id}']").size).to eq(2)
      expect(doc.css("section#availability").size).to eq(1)
      expect(doc.css("h2").map(&:text)).not_to include(I18n.t("product_availability.section.title"))
      expect(doc.css("h2").map(&:text).count(title)).to eq(1)
    end

    it "keeps the checkbox (and its unchecked value) in the product form, though the section sits outside it" do
      get edit_inventory_product_path(product)
      expect(doc.at_css("form#product-form input[name='product[track_inventory]']")).to be_nil # outside the <form> element…
      fields = doc.css("input[name='product[track_inventory]']")
      expect(fields.map { |f| [ f["type"], f["value"], f["form"] ] })
        .to contain_exactly([ "hidden", "0", "product-form" ], [ "checkbox", "1", "product-form" ]) # …but submitted with it
    end

    it "the New page shows the same section inside the form, warehouse settings following after the first save" do
      get new_inventory_product_path
      expect(doc.css("h2").map(&:text)).to include(title)
      section = doc.at_css("form#product-form [data-testid='inventory-tracking-section']")
      expect(section.at_css("input[type='checkbox'][name='product[track_inventory]']")).to be_present
      expect(section.at_css("[data-testid='availability-managed-elsewhere']")).to be_present
    end

    it "is translated in Arabic" do
      owner.update!(preferred_locale: "ar")
      get edit_inventory_product_path(product)
      expect(response.body).to include("تتبع المخزون والإشعارات وتوفر المنتج في المستودعات")
      expect(response.body).not_to include("translation missing")
    end
  end

  it "shows the section, wired to the checkbox, while tracking is on" do
    get edit_inventory_product_path(product)
    expect(section).not_to have_attribute_named("hidden")
    expect(section.css("[data-testid^='availability-card']")).not_to be_empty
    wiring = doc.at_css("[data-controller='inventory-tracking']")
    expect(wiring["data-inventory-tracking-section-value"]).to eq("availability")
    expect(wiring.at_css("input[name='product[track_inventory]'][data-action='change->inventory-tracking#toggle']")).to be_present
  end

  it "saving with tracking off keeps every warehouse setting and the history, and the section stays hidden" do
    before_settings = settings_snapshot
    before_audits   = AuditLog.where(auditable_type: "ProductWarehouseSetting").count
    before_moves    = InventoryMovement.where(product: product).order(:id).pluck(:id, :quantity, :direction)

    save_product("0")
    expect(response).to redirect_to(inventory_product_path(product))
    expect(product.reload).not_to be_track_inventory
    expect(settings_snapshot).to eq(before_settings)
    expect(AuditLog.where(auditable_type: "ProductWarehouseSetting").count).to eq(before_audits)
    expect(InventoryMovement.where(product: product).order(:id).pluck(:id, :quantity, :direction)).to eq(before_moves)

    get edit_inventory_product_path(product)
    expect(section).to have_attribute_named("hidden")
    expect(section.css("[data-testid^='availability-card']")).to be_empty # no figures, thresholds or reorder quantities
  end

  it "turning tracking on again shows the same settings (Active and Excluded), without duplicates" do
    before_settings = settings_snapshot
    save_product("0")
    save_product("1")
    expect(product.reload).to be_track_inventory
    expect(settings_snapshot).to eq(before_settings)

    get edit_inventory_product_path(product)
    expect(section).not_to have_attribute_named("hidden")
    expect(doc.at_css("#pws-#{branch_wh.id}-low")["value"]).to eq("2")
    expect(doc.at_css("#pws-#{branch_wh.id}-reorder")["value"]).to eq("5")
    expect(doc.at_css("[data-testid='availability-card-#{central.id}']").text).to include(I18n.t("product_availability.states.excluded"))
    expect(ProductWarehouseSetting.where(product: product).group(:warehouse_id).count.values).to all(eq(1))
  end

  it "still refuses turning tracking off while stock remains; the re-rendered form keeps the cards for when the box is ticked again" do
    InventoryMovement.create!(business: business, product: product, warehouse: branch_wh, direction: :in,
                              quantity: 4, unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
    before_settings = settings_snapshot

    save_product("0")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("stock in 1 warehouse")
    expect(product.reload).to be_track_inventory
    expect(settings_snapshot).to eq(before_settings)
    # Box shown off as submitted, so the section starts hidden — but the product
    # is still tracked, so its cards are there (shown again when the box is ticked).
    expect(section).to have_attribute_named("hidden")
    expect(doc.at_css("#pws-#{branch_wh.id}-low")["value"]).to eq("2")
  end

  it "still refuses it while an open inventory document references the product" do
    issue = business.stock_issues.build(warehouse: branch_wh, branch: branch_wh.branch, issued_on: Date.current, created_by: owner)
    issue.items.build(product: product, quantity: 1)
    issue.save!
    save_product("0")
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("1 open stock issue line")
    expect(product.reload).to be_track_inventory
  end

  it "the standalone availability page is not hidden for an untracked product (no checkbox there)" do
    save_product("0")
    get availability_inventory_product_path(product)
    expect(response).to have_http_status(:ok)
    expect(section).not_to have_attribute_named("hidden")
    expect(doc.at_css("[data-testid='untracked-notice']")).to be_present
  end
end
