require "rails_helper"

# Quick Issue — its own workflow (quick_issue_stock + the company setting),
# posted immediately: a standard StockIssue (workflow "quick_issue") driven
# through the regular workflow services in ONE transaction, with four
# mandatory audit entries, a fixed reason and EXACTLY ONE product. Stock is
# issued from a warehouse the actor is authorized to use
# (Inventory::IssueWarehouseReach): the only one automatically, otherwise the
# chosen one — re-checked, never trusted, never replaced. No consuming branch.
RSpec.describe Inventory::StockIssueQuickIssue do
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let!(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let!(:other_branch) { business.branches.create!(name: "Maadi", active: true) }
  let!(:main)      { branch_warehouse_for(branch, name: "Main") }          # Nasr City's own warehouse
  let!(:other_wh)  { branch_warehouse_for(other_branch, name: "Maadi WH") }
  let!(:annex)     { business.warehouses.create!(name: "Annex", kind: "central") }
  let!(:shampoo) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end
  let!(:towels) do
    business.products.create!(name: "Towels", sku: "TW-1", initial_cost_price: 4, average_cost_price: 4)
  end

  # Only quick_issue_stock (+ its view_inventory prerequisite) — no standard
  # Stock Issue permission at all.
  let(:actor) do
    role = business.permission_roles.create!(name: "Quick", permissions: %w[view_inventory quick_issue_stock])
    create(:user, business: business).tap do |u|
      u.update_column(:permission_role_id, role.id)
      WarehouseAssignment.create!(user: u, warehouse: main) # Main is the only warehouse they may use
    end
  end

  def receive!(product, quantity, warehouse: main, unit_cost: 10)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: quantity, unit_cost: unit_cost)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
  end

  # warehouse: omitted = let the service pick the actor's only warehouse.
  def quick_issue(product, quantity, user: actor, warehouse: :auto, reason: "internal_use", notes: nil)
    location = warehouse == :auto ? {} : { warehouse_id: warehouse.respond_to?(:id) ? warehouse.id.to_s : warehouse }
    described_class.new(actor: user, **location, product_id: product.respond_to?(:id) ? product.id.to_s : product,
                        quantity: quantity.is_a?(Array) ? quantity : quantity.to_s, reason: reason,
                        notes: notes).call
  end

  def on_hand(product, warehouse = main) = Inventory::StockLevels.new(product).in_warehouse(warehouse).to_d

  # Applies the settings; "unchanged" (already in that state) is fine — the
  # resulting state is what the examples rely on.
  def set_settings!(self_approval: "forbidden", quick_issue_enabled: true)
    result = OrganizationAccess::StockIssueWorkflowSettings.call(business: business, actor: owner, self_approval: self_approval,
                                                                 quick_issue_enabled: quick_issue_enabled)
    expect(result.ok? || result.error == :unchanged).to be(true), result.error.inspect
    business.reload
    expect(business.stock_issue_self_approval_allowed?).to eq(self_approval == "allowed")
    expect(business.quick_issue_enabled?).to eq(quick_issue_enabled)
  end

  before do
    receive!(shampoo, 10)
    receive!(towels, 20, unit_cost: 4)
    receive!(shampoo, 4, warehouse: annex)
    receive!(shampoo, 3, warehouse: other_wh)
  end

  describe "a successful Quick Issue" do
    it "posts one issued Stock Issue with exactly one line, in one step" do
      result = nil
      expect { result = quick_issue(shampoo, 3, notes: "Weekly supplies") }
        .to change(StockIssue, :count).by(1).and change(StockIssueItem, :count).by(1).and change(InventoryMovement, :count).by(1)

      expect(result).to be_ok
      issue = result.issue.reload
      expect(issue).to be_issued
      expect(issue).to be_quick_issue
      expect(issue.issue_reason).to eq("internal_use")
      expect(issue.notes).to eq("Weekly supplies")
      expect([ issue.created_by, issue.submitted_by, issue.approved_by, issue.issued_by ]).to all(eq(actor))
      expect(issue.items.map { |i| [ i.product_id, i.quantity.to_d ] }).to eq([ [ shampoo.id, 3 ] ])
      expect([ on_hand(shampoo), on_hand(towels), on_hand(shampoo, annex) ]).to eq([ 7, 20, 4 ])
    end

    it "uses decimal arithmetic up to the inventory precision (3 decimals)" do
      expect(quick_issue(shampoo, "2.125")).to be_ok
      expect(on_hand(shampoo)).to eq(BigDecimal("7.875"))
      expect(StockIssueItem.order(:id).last.quantity.to_d).to eq(BigDecimal("2.125"))
    end

    it "may issue exactly the quantity available" do
      expect(quick_issue(shampoo, 10)).to be_ok
      expect(on_hand(shampoo)).to eq(0)
    end

    it "values the line at average cost through the regular poster" do
      quick_issue(shampoo, 2)
      movement = InventoryMovement.where(reason: "stock_issue").order(:id).last
      expect(movement).to have_attributes(direction: "out", warehouse_id: main.id, branch_id: branch.id, product_id: shampoo.id)
      expect(movement.unit_cost.to_d).to eq(10)
    end
  end

  describe "exactly one product per Quick Issue" do
    it "has no multi-line contract (the lines: keyword is gone)" do
      expect {
        described_class.new(actor: actor, lines: [ { product_id: shampoo.id, quantity: 1 } ],
                            reason: "internal_use")
      }.to raise_error(ArgumentError)
    end

    [
      [ "several product ids", ->(s, t) { [ s.id.to_s, t.id.to_s ] }, "1" ],
      [ "a list of line hashes", ->(s, t) { [ { product_id: s.id }, { product_id: t.id } ] }, "1" ],
      [ "a product-id hash (nested-attributes shape)", ->(s, t) { { "0" => s.id.to_s, "1" => t.id.to_s } }, "1" ],
      [ "several quantities", ->(s, _t) { s.id.to_s }, [ "1", "2" ] ]
    ].each do |label, ids, quantity|
      it "refuses #{label} and posts nothing" do
        result = nil
        expect { result = quick_issue(ids.call(shampoo, towels), quantity) }
          .to not_change(StockIssue, :count).and not_change(InventoryMovement, :count).and not_change(AuditLog, :count)
        expect(result).not_to be_ok
        expect(result.error).to eq(I18n.t("inventory.quick_issue.errors.single_product_only"))
        expect(result.field_errors[:product]).to eq(result.error)
      end
    end

    it "is also enforced by StockIssue: a new quick_issue with two items (or none) is invalid" do
      two = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current, created_by: owner,
                                        workflow: "quick_issue", issue_reason: "internal_use", warehouse_source: "selected")
      two.items.build(product: shampoo, quantity: 1)
      two.items.build(product: towels, quantity: 1)
      expect(two).not_to be_valid
      expect(two.errors[:base]).to include(I18n.t("activerecord.errors.models.stock_issue.attributes.base.quick_issue_single_product"))

      two.items.last.mark_for_destruction
      expect(two).to be_valid
    end

    it "does not limit the Standard Stock Issue" do
      standard = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current, created_by: owner,
                                             warehouse_source: "selected")
      standard.items.build(product: shampoo, quantity: 1)
      standard.items.build(product: towels, quantity: 1)
      expect(standard).to be_valid
    end
  end

  describe "historical Quick Issues" do
    # A multi-product Quick Issue posted before the one-product rule — written
    # here without validation, as the earlier workflow left it.
    let!(:historical) do
      issue = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current - 3, created_by: owner,
                                          workflow: "quick_issue", issue_reason: "damaged", warehouse_source: "branch_warehouse",
                                          status: "issued", issue_number: "SI-HIST-1")
      issue.items.build(product: shampoo, quantity: 1)
      issue.items.build(product: towels, quantity: 2)
      issue.save!(validate: false)
      AuditLog.create!(business: business, actor: owner, auditable: issue, action: "confirm", metadata: { "quick_issue" => true })
      issue.reload
    end

    it "stay valid and untouched — the rule applies to new Quick Issues only" do
      snapshot = [ historical.updated_at, historical.items.order(:id).map { |i| [ i.product_id, i.quantity.to_d, i.updated_at ] },
                   AuditLog.for_auditable(historical).order(:id).map(&:attributes) ]

      expect(historical).to be_valid
      expect(quick_issue(shampoo, 1)).to be_ok

      historical.reload
      expect([ historical.updated_at, historical.items.order(:id).map { |i| [ i.product_id, i.quantity.to_d, i.updated_at ] },
               AuditLog.for_auditable(historical).order(:id).map(&:attributes) ]).to eq(snapshot)
      expect(historical.items.size).to eq(2)
    end
  end

  describe "the four mandatory audit entries" do
    it "writes create, submit, an automatic Quick Issue approval and confirm, in the actor's name" do
      issue = quick_issue(shampoo, 2, reason: "damaged").issue
      logs  = AuditLog.for_auditable(issue).order(:id)

      expect(logs.map(&:action)).to eq(%w[create submit_for_approval approve confirm])
      expect(logs.map(&:actor)).to all(eq(actor))
      approve = logs.find { |l| l.action == "approve" }
      expect(approve.metadata).to include("quick_issue" => true, "automatic" => true, "workflow" => "quick_issue",
                                          "issue_reason" => "damaged")
      expect(approve.metadata["reserved"][shampoo.id.to_s].to_d).to eq(2)
    end

    %w[create submit_for_approval approve confirm].each do |action|
      it "rolls everything back when the #{action} audit entry cannot be written" do
        allow(AuditLog).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
          raise ActiveRecord::RecordInvalid, AuditLog.new if kwargs[:action] == action

          original.call(*args, **kwargs)
        end

        result = nil
        expect { result = quick_issue(shampoo, 1) }
          .to not_change(StockIssue, :count).and not_change(StockIssueItem, :count)
          .and not_change(InventoryMovement, :count)
        expect(result).not_to be_ok
        expect(result.error).to eq(I18n.t("inventory.quick_issue.errors.audit_failed"))
        expect(Inventory::StockAvailability.reserved_items.count).to eq(0)
      end
    end
  end

  describe "permission independence" do
    it "needs only quick_issue_stock — not create, approve or confirm" do
      expect(actor.can?(:create_stock_issues) || actor.can?(:approve_stock_issues) || actor.can?(:confirm_stock_issues)).to be false
      expect(quick_issue(shampoo, 1)).to be_ok
    end

    it "refuses create + approve + confirm without quick_issue_stock" do
      full = stock_issue_user(business, :create_stock_issues, :approve_stock_issues, :confirm_stock_issues)
      result = nil
      expect { result = quick_issue(shampoo, 1, user: full) }.not_to change(StockIssue, :count)
      expect(result.error).to eq(I18n.t("inventory.quick_issue.errors.not_permitted"))
    end

    it "stays usable when standard self-approval is forbidden" do
      set_settings!(self_approval: "forbidden")
      expect(quick_issue(shampoo, 1)).to be_ok
    end

    it "is refused to employees but not to the owner when the company setting is disabled" do
      set_settings!(quick_issue_enabled: false)
      expect(quick_issue(shampoo, 1, user: actor.reload).error).to eq(I18n.t("inventory.quick_issue.errors.not_permitted"))
      expect(quick_issue(shampoo, 1, user: owner.reload, warehouse: other_wh)).to be_ok
    end
  end

  describe "the internal Quick Issue authorization cannot be forged" do
    let(:pending) do
      issue = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current, created_by: owner)
      issue.items.build(product: shampoo, quantity: 1)
      save_stock_issue_in_status!(issue, :pending_approval)
    end

    it "refuses a stand-in object, even one claiming identity" do
      forged = Object.new
      def forged.equal?(*) = true
      def forged.==(*) = true

      [ Object.new, forged, :quick_issue, true ].each do |fake|
        expect(Inventory::StockIssueAuthorization.step_permitted?(actor, :approve, context: fake)).to be(false)
        expect(Inventory::StockIssueApproval.new(stock_issue_id: pending.id, actor: actor, context: fake).approve!.error)
          .to eq(Inventory::StockIssueAuthorization.message)
      end
      expect(pending.reload).to be_pending_approval
    end

    it "keeps the context private" do
      expect { Inventory::StockIssueQuickIssue::CONTEXT }.to raise_error(NameError)
    end
  end

  describe "warehouse selection and authorization" do
    it "uses the actor's only authorized warehouse automatically — never central or another one" do
      expect(quick_issue(shampoo, 2)).to be_ok
      expect([ on_hand(shampoo), on_hand(shampoo, annex), on_hand(shampoo, other_wh) ]).to eq([ 8, 4, 3 ])
      issue = StockIssue.order(:id).last
      expect(issue).to have_attributes(warehouse_id: main.id, warehouse_source: "selected", branch_id: branch.id)
    end

    it "uses the chosen warehouse when the actor may use several; requires a choice then" do
      WarehouseAssignment.create!(user: actor, warehouse: annex)
      expect(quick_issue(shampoo, 1).field_errors[:warehouse]).to eq(I18n.t("inventory.issue_warehouse.errors.required"))

      expect(quick_issue(shampoo, 3, warehouse: annex)).to be_ok
      expect([ on_hand(shampoo, annex), on_hand(shampoo) ]).to eq([ 1, 10 ])
      expect(StockIssue.order(:id).last).to have_attributes(warehouse_id: annex.id, branch_id: nil) # central: unattributed
    end

    it "refuses an unauthorized, inactive or foreign warehouse — never falling back to the authorized one" do
      foreign = create(:business).warehouses.create!(name: "Foreign", kind: "central")
      [ annex, other_wh, foreign ].each do |warehouse|
        result = quick_issue(shampoo, 1, warehouse: warehouse)
        expect(result).not_to be_ok
        expect(result.field_errors[:warehouse]).to eq(I18n.t("inventory.issue_warehouse.errors.not_allowed"))
      end
      main.update_column(:status, "inactive")
      expect(quick_issue(shampoo, 1, warehouse: main)).not_to be_ok
      expect(StockIssue.count).to eq(0)
      expect(InventoryMovement.where(reason: "stock_issue")).to be_empty
    end

    it "refuses an actor without any accessible active warehouse" do
      main.update_column(:status, "inactive")
      result = quick_issue(shampoo, 1)
      expect(result.error).to eq(I18n.t("inventory.issue_warehouse.errors.none_accessible"))
    end

    it "has no consuming-branch input" do
      expect {
        described_class.new(actor: actor, branch_id: branch.id, product_id: shampoo.id, quantity: "1", reason: "internal_use")
      }.to raise_error(ArgumentError)
    end

    it "re-verifies the warehouse under lock at approval and confirmation" do
      checked = []
      allow_any_instance_of(Inventory::IssueWarehouseReach).to receive(:verify_under_lock).and_wrap_original do |method, record|
        checked << record.warehouse_id
        method.call(record)
      end
      expect(quick_issue(shampoo, 1)).to be_ok
      expect(checked).to eq([ main.id, main.id ])
    end

    it "lets the owner use any active warehouse of the business" do
      expect(quick_issue(shampoo, 1, user: owner, warehouse: other_wh)).to be_ok
      expect(on_hand(shampoo, other_wh)).to eq(2)
    end
  end

  describe "reason" do
    it "requires one of the fixed reasons" do
      expect(quick_issue(shampoo, 1, reason: nil).error).to eq(I18n.t("inventory.quick_issue.errors.reason_required"))
      expect(quick_issue(shampoo, 1, reason: "adjustment").error).to eq(I18n.t("inventory.quick_issue.errors.reason_invalid"))
      expect(StockIssue.count).to eq(0)
    end

    it "requires Notes for Other (on the notes field), and records them as the reason note and in the audit" do
      result = nil
      expect { result = quick_issue(shampoo, 1, reason: "other", notes: "   ") }.not_to change(StockIssue, :count)
      expect(result.field_errors[:notes]).to eq(I18n.t("inventory.quick_issue.errors.notes_required_for_other"))

      issue = quick_issue(shampoo, 1, reason: "other", notes: "Sample for a client").issue.reload
      expect([ issue.issue_reason, issue.notes, issue.issue_reason_note ]).to eq([ "other", "Sample for a client", "Sample for a client" ])
      approve = AuditLog.for_auditable(issue).find_by(action: "approve")
      expect(approve.metadata["issue_reason_note"]).to eq("Sample for a client")
    end

    it "keeps Notes optional — and no reason note — for every other reason" do
      issue = quick_issue(shampoo, 1, reason: "damaged", notes: "Torn box").issue.reload
      expect([ issue.notes, issue.issue_reason_note ]).to eq([ "Torn box", nil ])
      expect(quick_issue(shampoo, 1, reason: "lost")).to be_ok
    end

    it "has no separate description input" do
      expect {
        described_class.new(actor: actor, product_id: shampoo.id, quantity: "1", reason: "other", reason_note: "x")
      }.to raise_error(ArgumentError)
    end

    it "accepts every fixed reason" do
      StockIssue::QUICK_ISSUE_REASONS.each do |reason|
        expect(quick_issue(towels, 1, reason: reason, notes: ("why" if reason == "other"))).to be_ok, reason
      end
    end
  end

  describe "quantity and product validation (atomic: nothing posted)" do
    [ "0", "-1", "", "abc", "1.2345", "0.0001" ].each do |bad|
      it "refuses the quantity #{bad.inspect} with a message on the quantity" do
        result = nil
        expect { result = quick_issue(shampoo, bad) }
          .to not_change(StockIssue, :count).and not_change(InventoryMovement, :count).and not_change(AuditLog, :count)
        expect(result).not_to be_ok
        expect(result.field_errors[:quantity]).to eq(I18n.t("inventory.quick_issue.errors.quantity_invalid"))
        expect(result.error).to eq(result.field_errors[:quantity])
      end
    end

    it "refuses more than is available, naming the warehouse and the available quantity" do
      result = nil
      expect { result = quick_issue(shampoo, "10.001") }
        .to not_change(StockIssue, :count).and not_change(InventoryMovement, :count).and not_change(AuditLog, :count)
      expect(result.field_errors[:quantity]).to include(shampoo.name, main.name, "10")
      expect(on_hand(shampoo)).to eq(10)
    end

    it "refuses a missing product, an unknown one, and products of another business" do
      expect(quick_issue("", 1).field_errors[:product]).to eq(I18n.t("inventory.quick_issue.errors.product_required"))
      expect(quick_issue("999999", 1).field_errors[:product]).to eq(I18n.t("inventory.quick_issue.errors.product_unavailable"))
      foreign = create(:business).products.create!(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1)
      expect(quick_issue(foreign, 1).field_errors[:product]).to eq(I18n.t("inventory.quick_issue.errors.product_unavailable"))
      expect(StockIssue.count).to eq(0)
    end

    it "measures availability in the selected warehouse only (stock elsewhere does not count)" do
      expect(quick_issue(shampoo, 4, user: owner, warehouse: other_wh)).not_to be_ok # Maadi WH holds 3
      expect(quick_issue(shampoo, 3, user: owner, warehouse: other_wh)).to be_ok
    end

    it "reports the same availability figure the popup shows" do
      available = described_class.available_by(warehouse_ids: [ main.id, other_wh.id, annex.id ], product_ids: [ shampoo.id ])
      expect(available).to eq({ [ main.id, shampoo.id ] => 10, [ other_wh.id, shampoo.id ] => 3, [ annex.id, shampoo.id ] => 4 })
    end
  end

  describe "stock integrity under lock" do
    it "cannot take stock reserved by another approved issue" do
      reserved = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current)
      reserved.items.build(product: shampoo, quantity: 8)
      save_stock_issue_in_status!(reserved, :approved)

      expect(quick_issue(shampoo, 3)).not_to be_ok
      expect(quick_issue(shampoo, 2)).to be_ok
      expect(reserved.reload).to be_approved
    end

    it "re-checks availability under the product locks (the pre-check is not authoritative)" do
      # Only the service's read-only pre-check (warehouse_ids as an Array) sees a
      # stale, optimistic figure; the locked checks (StockAvailability.validate!,
      # scalar warehouse id) read the real ledger.
      allow(Inventory::StockAvailability).to receive(:on_hand_by).and_wrap_original do |original, **kwargs|
        result = original.call(**kwargs)
        kwargs[:warehouse_ids].is_a?(Array) ? result.transform_values { |v| v + 100 } : result
      end

      result = nil
      expect { result = quick_issue(shampoo, 50) }.to not_change(StockIssue, :count).and not_change(InventoryMovement, :count)
      expect(result).not_to be_ok
    end

    it "locks the product at approval and at posting" do
      allow(Inventory::StockAvailability).to receive(:lock_products!).and_call_original
      quick_issue(shampoo, 1)
      expect(Inventory::StockAvailability).to have_received(:lock_products!).with([ shampoo.id ]).at_least(:twice)
    end

    it "rolls the whole issue back when a later workflow step fails" do
      failing = Inventory::StockIssueConfirmationService::Result.new(ok: false, error: "posting refused")
      allow_any_instance_of(Inventory::StockIssueConfirmationService).to receive(:call).and_return(failing)

      result = nil
      expect { result = quick_issue(shampoo, 1) }
        .to not_change(StockIssue, :count).and not_change(AuditLog, :count).and not_change(InventoryMovement, :count)
      expect(result.error).to eq("posting refused")
    end
  end
end
