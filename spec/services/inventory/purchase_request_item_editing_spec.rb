require "rails_helper"

# Editing a Purchase Request's items before approval, through
# Inventory::PurchaseRequestUpdater (items_attributes), and the approval rule
# that follows: draft and pending approval are editable (pending: items only,
# and it stays pending); nothing from approval on — approval is what opens
# receiving and advances. The last reviewer to change the items while pending
# may not approve them (owner exempt, like self-approval).
RSpec.describe "Purchase Request item editing before approval", type: :model do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:beta)      { business.suppliers.create!(name: "Beta") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:shampoo)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 10, default_supplier: supplier) }
  let(:gel)       { business.products.create!(name: "Gel", sku: "GE-1", average_cost_price: 20, default_supplier: beta) }
  let(:dye)       { business.products.create!(name: "Dye", sku: "DY-1", average_cost_price: 30) }

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: [ "view_inventory", *permissions ])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:creator)    { user_with("create_purchase_requests") }
  let(:reviewer)   { user_with("approve_purchase_requests") }
  let(:reviewer_2) { user_with("approve_purchase_requests") }

  # Shampoo 4 × 10 from Acme, Gel 2 × 20 from Beta = 80.
  let(:request) do
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: creator)
    pr.items.build(product: shampoo, quantity: 4, unit_price: 10, supplier: supplier)
    pr.items.build(product: gel, quantity: 2, unit_price: 20, supplier: beta)
    pr.save!
    pr
  end
  let(:shampoo_line) { request.items.find_by!(product: shampoo) }
  let(:gel_line)     { request.items.find_by!(product: gel) }

  def edit(lines, actor: creator, **other)
    Inventory::PurchaseRequestUpdater.new(request.id, actor: actor,
                                          attributes: { items_attributes: lines }.merge(other)).call
  end

  def submit! = Inventory::PurchaseRequestApproval.new(purchase_request_id: request.id, actor: creator).submit!
  def approve(actor) = Inventory::PurchaseRequestApproval.new(purchase_request_id: request.id, actor: actor).approve!
  def message(key, **) = I18n.t("inventory.purchase_requests.errors.#{key}", **)

  describe "a draft" do
    it "edits a line's product, quantity and price; the totals follow" do
      result = edit({ "0" => { id: shampoo_line.id, product_id: dye.id, quantity: 5, unit_price: 30 } })

      expect(result).to be_ok
      line = request.reload.items.find(shampoo_line.id)
      expect(line).to have_attributes(product_id: dye.id, quantity: 5, unit_price: 30, total_cost: 150)
      expect(request.total_amount).to eq(150 + 40)
    end

    it "adds and deletes lines; the total follows" do
      expect(edit({ "0" => { product_id: dye.id, quantity: 1, unit_price: 30 } })).to be_ok
      expect(request.reload.total_amount).to eq(110)

      expect(edit({ "0" => { id: gel_line.id, product_id: gel.id, _destroy: "1" } })).to be_ok
      expect(request.reload.items.map(&:product)).to contain_exactly(shampoo, dye)
      expect(request.total_amount).to eq(70)
    end

    it "keeps each line's supplier: editing quantity/price or the product never resets it, and the catalog is untouched" do
      edit({ "0" => { id: gel_line.id, product_id: gel.id, quantity: 9, unit_price: 21 } })
      expect(gel_line.reload.supplier).to eq(beta)

      # The product changes; the line keeps the supplier it was sent with (Beta), not Dye's (none).
      edit({ "0" => { id: gel_line.id, product_id: dye.id, supplier_id: beta.id } })
      expect(gel_line.reload).to have_attributes(product_id: dye.id, supplier_id: beta.id)

      expect(dye.reload.default_supplier_id).to be_nil
      expect([ shampoo.reload.average_cost_price, gel.reload.default_supplier ]).to eq([ 10, beta ])
    end

    it "refuses a duplicate product, zero or negative quantity and price, writing nothing" do
      expect(edit({ "0" => { product_id: gel.id, quantity: 1, unit_price: 5 } }).error).to eq(message(:duplicate_product))
      [ { quantity: 0 }, { quantity: -2 }, { unit_price: 0 }, { unit_price: -1 } ].each do |bad|
        expect(edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id }.merge(bad) })).not_to be_ok
      end
      expect(request.reload.items.map { |i| [ i.quantity, i.unit_price ] }).to contain_exactly([ 4, 10 ], [ 2, 20 ])
    end

    it "keeps the request's one warehouse (a line has none of its own)" do
      edit({ "0" => { product_id: dye.id, quantity: 1, unit_price: 30 } })
      expect(request.reload.warehouse).to eq(warehouse)
      expect(request.items.map(&:source_warehouse_id)).to all(be_nil)
    end

    it "refuses removing the last line" do
      edit({ "0" => { id: gel_line.id, product_id: gel.id, _destroy: "1" } })
      expect(edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, _destroy: "1" } })).not_to be_ok
      expect(request.reload.items.count).to eq(1)
    end

    it "audits the exact line changes" do
      edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, quantity: 6 }, "1" => { product_id: dye.id, quantity: 1, unit_price: 30 },
             "2" => { id: gel_line.id, product_id: gel.id, _destroy: "1" } })

      changes = AuditLog.where(auditable: request, action: "update").sole.metadata["item_changes"]
      expect(changes["changed"]).to eq([ { "item_id" => shampoo_line.id, "from" => { "quantity" => "4.0" },
                                           "to" => { "quantity" => "6.0" } } ])
      expect(changes["added"].sole).to include("product_id" => dye.id, "quantity" => "1.0", "unit_price" => "30.0")
      expect(changes["removed"].sole).to include("item_id" => gel_line.id, "product_id" => gel.id)
    end
  end

  describe "pending approval" do
    before { submit! }

    it "edits items and stays pending; audited as a review edit" do
      result = edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, quantity: 8 } }, actor: reviewer)

      expect(result).to be_ok
      expect(request.reload).to be_pending_approval
      expect(shampoo_line.reload.quantity).to eq(8)
      expect(request.total_amount).to eq(120)
      audit = AuditLog.where(auditable: request, action: "review_edit").sole
      expect(audit).to have_attributes(actor_id: reviewer.id)
      expect(audit.metadata["item_changes"]["changed"].sole["to"]).to eq("quantity" => "8.0")
    end

    it "refuses anything but the items" do
      result = edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, quantity: 8 } }, actor: reviewer, notes: "changed")
      expect(result.error).to eq(message(:only_items_during_review))
      expect(shampoo_line.reload.quantity).to eq(4)
    end

    describe "approval after a review edit" do
      it "the last editor may not approve; another approver may" do
        edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, quantity: 8 } }, actor: reviewer)

        expect(approve(reviewer).error).to eq(message(:review_editor_cannot_approve))
        expect(request.reload).to be_pending_approval
        expect(approve(reviewer_2)).to be_ok
      end

      it "only the LAST editor is blocked" do
        edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, quantity: 8 } }, actor: reviewer)
        edit({ "0" => { id: gel_line.id, product_id: gel.id, quantity: 3 } }, actor: reviewer_2)

        expect(approve(reviewer_2).error).to eq(message(:review_editor_cannot_approve))
        expect(approve(reviewer)).to be_ok
      end

      it "the owner is exempt, like self-approval" do
        edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, quantity: 8 } }, actor: owner)
        expect(approve(owner)).to be_ok
      end

      it "bulk approval refuses the whole batch, naming the request" do
        edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, quantity: 8 } }, actor: reviewer)
        result = Inventory::PurchaseRequestBulkApproval.new(purchase_request_ids: [ request.id ], actor: reviewer).call
        expect(result.error).to eq(message(:bulk_review_editor, numbers: request.request_number))
        expect(request.reload).to be_pending_approval
      end
    end
  end

  describe "from approval on, items are locked" do
    %w[approved partially_received fully_received partially_closed rejected cancelled].each do |status|
      it "#{status}: refused, nothing written" do
        request.update_column(:status, status)
        result = edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, quantity: 99 } }, actor: owner)
        expect(result.error).to eq(message(:invalid_transition))
        expect(shampoo_line.reload.quantity).to eq(4)
      end
    end

    it "once receiving or funding has started (both need an approved request)" do
      request.update_column(:status, "approved")
      request.update_column(:responsible_employee_id, purchaser_with_custody(business).id)
      Inventory::PurchaseRequestAdvanceRecorder.new(
        purchase_request_id: request.id, actor: owner, params: { amount: 10, source_kind: "company_cash", paid_on: Date.current }
      ).call
      receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request,
                                              received_on: Date.current, created_by: owner, funding_source_kind: "supplier_credit")
      receipt.items.build(product: shampoo, quantity: 1, unit_cost: 10, purchase_request_item: shampoo_line)
      receipt.save!
      expect(request.advances).to exist

      expect(edit({ "0" => { id: shampoo_line.id, product_id: shampoo.id, quantity: 99 } }, actor: owner).error).to eq(message(:invalid_transition))
      expect(edit({ "0" => { id: gel_line.id, product_id: gel.id, _destroy: "1" } }, actor: owner).error).to eq(message(:invalid_transition))
      expect(request.reload.items.count).to eq(2)
    end
  end

  describe "policy (edit_items?)" do
    def allowed?(user) = PurchaseRequestPolicy.new(user, request.reload).edit_items?

    it "draft: whoever may edit the draft; pending: reviewers only; never after" do
      viewer = user_with
      expect([ allowed?(creator), allowed?(reviewer), allowed?(viewer) ]).to eq([ true, false, false ])

      submit!
      expect([ allowed?(creator), allowed?(reviewer), allowed?(user_with("manage_inventory")), allowed?(viewer) ])
        .to eq([ false, true, true, false ])

      request.update_column(:status, "approved")
      expect([ allowed?(creator), allowed?(reviewer), allowed?(owner) ]).to eq([ false, false, false ])
    end
  end
end
