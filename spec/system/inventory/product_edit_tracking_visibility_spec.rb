require "rails_helper"

# In the browser: unticking "Track stock quantity" hides the whole
# "Product availability in warehouses" section at once; ticking it again shows
# the same cards. Toggling writes nothing; saving is still decided (and, while
# stock remains, refused) by the server.
RSpec.describe "Product Edit — Track stock quantity hides warehouse availability (browser)", type: :system do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :owner, business: business) }
  let!(:central)   { business.warehouses.create!(name: "Central WH", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City", kind: "branch", branch: create(:branch, business: business)) }
  let!(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1) }
  let(:manager)    { Inventory::ProductAvailabilityManager.new(actor: owner) }
  let(:checkbox)   { find("input[type='checkbox'][name='product[track_inventory]']") }

  def settings_snapshot = ProductWarehouseSetting.order(:id).map(&:attributes)
  def section_visible? = page.has_css?("section#availability", visible: true, wait: 0)

  before do
    manager.save_settings(product_id: product.id, warehouse_id: central.id, low_stock_level: 8, reorder_quantity: 20)
    manager.save_settings(product_id: product.id, warehouse_id: branch_wh.id, low_stock_level: 2, reorder_quantity: 5)
    sign_in owner
  end

  it "hides the section immediately when unticked and shows the same cards when ticked again, writing nothing" do
    before_settings = settings_snapshot
    visit edit_inventory_product_path(product)
    expect(page).to have_css("[data-testid='availability-card-#{branch_wh.id}']", visible: true)

    checkbox.uncheck
    expect(page).to have_no_css("section#availability", visible: true)
    expect(page).to have_no_css("[data-testid^='availability-card']", visible: true)
    expect(page).to have_no_field("pws-#{branch_wh.id}-low")

    checkbox.check
    expect(page).to have_css("section#availability", visible: true)
    expect(page).to have_field("pws-#{branch_wh.id}-low", with: "2")
    expect(page).to have_field("pws-#{central.id}-reorder", with: "20")
    expect(settings_snapshot).to eq(before_settings)
  end

  it "after saving with tracking off the section stays hidden; turning tracking back on restores the settings" do
    before_settings = settings_snapshot
    visit edit_inventory_product_path(product)
    checkbox.uncheck
    click_button I18n.t("common.save")
    expect(page).to have_text(I18n.t("inventory.products.all_saved"))
    expect(product.reload).not_to be_track_inventory

    visit edit_inventory_product_path(product)
    expect(checkbox).not_to be_checked
    expect(section_visible?).to be(false)

    checkbox.check
    click_button I18n.t("common.save")
    expect(page).to have_text(I18n.t("inventory.products.all_saved"))
    visit edit_inventory_product_path(product)
    expect(page).to have_field("pws-#{branch_wh.id}-low", with: "2")
    expect(page).to have_field("pws-#{central.id}-low", with: "8")
    expect(settings_snapshot).to eq(before_settings)
  end

  it "a refused save (stock remains) keeps the product tracked; ticking the box shows the cards again" do
    InventoryMovement.create!(business: business, product: product, warehouse: branch_wh, direction: :in,
                              quantity: 4, unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
    visit edit_inventory_product_path(product)
    checkbox.uncheck
    click_button I18n.t("common.save")

    expect(page).to have_text("stock in 1 warehouse")
    expect(product.reload).to be_track_inventory
    expect(section_visible?).to be(false) # follows the (still unticked) box
    checkbox.check
    expect(page).to have_field("pws-#{branch_wh.id}-low", with: "2")
  end
end
