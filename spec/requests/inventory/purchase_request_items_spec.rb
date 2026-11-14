require "rails_helper"

# The Purchase Request page's item editor endpoints (add / edit / delete one
# line) — authorized by PurchaseRequestPolicy#edit_items? and saved through
# Inventory::PurchaseRequestUpdater.
RSpec.describe "Purchase Request items (HTTP)", type: :request do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:acme)      { business.suppliers.create!(name: "Acme") }
  let(:shampoo)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 10, default_supplier: acme) }
  let(:dye)       { business.products.create!(name: "Dye", sku: "DY-1", average_cost_price: 30) }

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: [ "view_inventory", *permissions ])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:creator)  { user_with("create_purchase_requests") }
  let(:reviewer) { user_with("approve_purchase_requests") }

  let(:request_record) do
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: creator)
    pr.items.build(product: shampoo, quantity: 4, unit_price: 10, supplier: acme)
    pr.save!
    pr
  end
  let(:line) { request_record.items.find_by!(product: shampoo) }

  def line_params(**attrs) = { purchase_request: { items_attributes: { "0" => attrs } } }
  def html = Nokogiri::HTML(response.body)

  describe "on a draft (its creator)" do
    before { sign_in creator }

    it "adds, edits and deletes a line, with the total recalculated" do
      post inventory_purchase_request_items_path(request_record),
           params: line_params(product_id: dye.id, quantity: 2, unit_price: 30)
      expect(response).to redirect_to(inventory_purchase_request_path(request_record, anchor: "items"))
      expect(flash[:notice]).to eq(I18n.t("inventory.purchase_requests.item_added"))
      expect(request_record.reload.total_amount).to eq(100)

      patch inventory_purchase_request_item_path(request_record, line),
            params: line_params(product_id: shampoo.id, supplier_id: acme.id, quantity: 5, unit_price: 12)
      expect(line.reload).to have_attributes(quantity: 5, unit_price: 12, supplier_id: acme.id)
      expect(request_record.reload.total_amount).to eq(120)

      delete inventory_purchase_request_item_path(request_record, line)
      expect(flash[:notice]).to eq(I18n.t("inventory.purchase_requests.item_deleted"))
      expect(request_record.reload.items.map(&:product)).to eq([ dye ])
    end

    it "refuses invalid values and a missing product with a message, changing nothing" do
      patch inventory_purchase_request_item_path(request_record, line), params: line_params(product_id: shampoo.id, quantity: -1, unit_price: 10)
      expect(flash[:alert]).to be_present
      patch inventory_purchase_request_item_path(request_record, line), params: line_params(product_id: "", quantity: 9, unit_price: 10)
      expect(flash[:alert]).to eq(I18n.t("inventory.purchase_requests.errors.item_product_required"))
      expect(line.reload).to have_attributes(product_id: shampoo.id, quantity: 4)
    end

    it "shows Edit / Delete per row and Add Product, and the editor modal" do
      get inventory_purchase_request_path(request_record)
      expect(html.at_css("#item-#{line.id} [data-testid='edit-item']")).to be_present
      expect(html.at_css("#item-#{line.id} form[action='#{inventory_purchase_request_item_path(request_record, line)}']")).to be_present
      expect(html.at_css("[data-testid='add-item']")).to be_present
      expect(html.at_css("[data-purchase-request-item-editor-target='modal']")).to be_present
    end
  end

  describe "pending approval" do
    before { Inventory::PurchaseRequestApproval.new(purchase_request_id: request_record.id, actor: creator).submit! }

    it "a reviewer edits the items; the request stays pending and the editor can't approve it" do
      sign_in reviewer
      patch inventory_purchase_request_item_path(request_record, line), params: line_params(product_id: shampoo.id, quantity: 7, unit_price: 10)
      expect(line.reload.quantity).to eq(7)
      expect(request_record.reload).to be_pending_approval

      get inventory_purchase_request_path(request_record)
      expect(html.at_css("[data-testid='review-editor-notice']")).to be_present
      post approve_inventory_purchase_request_path(request_record)
      expect(request_record.reload).to be_pending_approval
      expect(flash[:alert]).to eq(I18n.t("inventory.purchase_requests.errors.review_editor_cannot_approve"))
    end

    it "the creator may no longer edit it, and sees no item actions" do
      sign_in creator
      patch inventory_purchase_request_item_path(request_record, line), params: line_params(product_id: shampoo.id, quantity: 7, unit_price: 10)
      expect(line.reload.quantity).to eq(4)

      get inventory_purchase_request_path(request_record)
      expect(html.at_css("[data-testid='edit-item']")).to be_nil
      expect(html.at_css("[data-testid='add-item']")).to be_nil
    end
  end

  it "after approval: no actions, and direct requests change nothing" do
    request_record.update_column(:status, "approved")
    owner = create(:user, :super_admin, business: business)
    sign_in owner

    get inventory_purchase_request_path(request_record)
    expect(html.at_css("[data-testid='edit-item']")).to be_nil

    patch inventory_purchase_request_item_path(request_record, line), params: line_params(product_id: shampoo.id, quantity: 99, unit_price: 10)
    delete inventory_purchase_request_item_path(request_record, line)
    post inventory_purchase_request_items_path(request_record), params: line_params(product_id: dye.id, quantity: 1, unit_price: 1)
    expect(request_record.reload.items.map { |i| [ i.product_id, i.quantity ] }).to eq([ [ shampoo.id, 4 ] ])
  end

  it "a user without purchase permissions is denied" do
    sign_in user_with
    post inventory_purchase_request_items_path(request_record), params: line_params(product_id: dye.id, quantity: 1, unit_price: 1)
    expect(request_record.reload.items.count).to eq(1)
  end
end
