require "rails_helper"

# Stock Issue — warehouse-based authorization (approved Nov 24 2026): stock is
# issued from a warehouse the actor is authorized to use
# (Inventory::IssueWarehouseReach, built on the approved warehouse-access rule).
# No consuming branch is selected; the issue's branch is cost attribution
# derived from its warehouse. Every service re-checks the warehouse.
RSpec.describe "Stock Issue warehouse authorization" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:nasr)     { business.branches.create!(name: "Nasr City", active: true) }
  let!(:nasr_wh) { branch_warehouse_for(nasr, name: "Nasr WH") }
  let!(:central) { business.warehouses.create!(name: "Central", kind: "central") }
  let!(:annex)   { business.warehouses.create!(name: "Annex", kind: "central") }
  let!(:closed)  { business.warehouses.create!(name: "Closed", kind: "central").tap { |w| w.update_column(:status, "inactive") } }
  let(:foreign_wh) { create(:business).warehouses.create!(name: "Foreign", kind: "central") }
  let!(:shampoo) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }

  let(:requester) { stock_issue_user(business, :create_stock_issues) }
  let(:approver)  { stock_issue_user(business, :approve_stock_issues, :confirm_stock_issues) }

  def receive!(warehouse, quantity)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: shampoo, quantity: quantity, unit_cost: 10)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
  end

  def on_hand(warehouse) = Inventory::StockLevels.new(shampoo).in_warehouse(warehouse).to_d

  def draft!(warehouse_id, actor: requester, quantity: 2)
    issue = business.stock_issues.build(warehouse_id: warehouse_id, issued_on: Date.current, created_by: actor)
    issue.items.build(product: shampoo, quantity: quantity)
    [ issue, Inventory::StockIssueDraftService.new(issue, actor: actor).call ]
  end

  before do
    receive!(nasr_wh, 10)
    receive!(central, 20)
    receive!(annex, 30)
  end

  describe Inventory::IssueWarehouseReach do
    it "selects the only authorized active warehouse automatically" do
      restrict_to_warehouses!(requester, central)
      reach = described_class.for(requester)
      expect(reach.warehouses).to eq([ central ])
      expect(reach.default_warehouse_id).to eq(central.id)
    end

    it "lists only the authorized active warehouses when there are several — no default" do
      restrict_to_warehouses!(requester, central, annex, closed)
      reach = described_class.for(requester)
      expect(reach.warehouses.map(&:name)).to eq(%w[Annex Central]) # never the inactive one, never the others
      expect(reach.default_warehouse_id).to be_nil
    end

    it "gives nothing — and explains why — without any accessible active warehouse" do
      restrict_to_warehouses!(requester, closed)
      reach = described_class.for(requester)
      expect(reach).to be_none
      expect(reach.message).to eq(I18n.t("inventory.issue_warehouse.errors.none_accessible"))
    end

    it "lets the owner use every active warehouse of the business, never another business's" do
      reach = described_class.for(owner)
      expect(reach.warehouses).to contain_exactly(nasr_wh, central, annex)
      expect(reach.issuable?(foreign_wh.id)).to be(false)
      expect(reach.issuable?(closed.id)).to be(false)
    end

    it "refuses malformed ids" do
      reach = described_class.for(owner)
      expect([ nil, "", "abc", [ central.id ], "#{central.id} OR 1=1" ].map { |id| reach.issuable?(id) }).to all(be(false))
    end
  end

  describe "creating a draft" do
    it "uses the selected authorized warehouse — no consuming branch involved" do
      restrict_to_warehouses!(requester, central, annex)
      issue, result = draft!(annex.id)
      expect(result).to be_ok
      expect(issue.reload).to have_attributes(warehouse_id: annex.id, warehouse_source: "selected", branch_id: nil)
    end

    it "derives the cost-attribution branch from a branch warehouse" do
      restrict_to_warehouses!(requester, nasr_wh)
      issue, = draft!(nasr_wh.id)
      expect(issue.reload.branch_id).to eq(nasr.id)
    end

    {
      "an unauthorized warehouse" => ->(ctx) { ctx.annex.id },
      "an inactive warehouse"     => ->(ctx) { ctx.closed.id },
      "another business's warehouse" => ->(ctx) { ctx.foreign_wh.id },
      "no warehouse"              => ->(_ctx) { nil }
    }.each do |label, pick|
      it "refuses #{label}, writing nothing" do
        restrict_to_warehouses!(requester, central, closed)
        issue = result = nil
        expect { issue, result = draft!(pick.call(self)) }.not_to change { [ StockIssue.count, AuditLog.count ] }
        expect(result).not_to be_ok
        expect(issue.errors[:base]).to be_present
      end
    end

    it "refuses everything to an actor without any accessible warehouse" do
      restrict_to_warehouses!(requester, closed)
      _, result = draft!(central.id)
      expect(result).not_to be_ok
    end

    it "still needs the operation permission, whatever the warehouse access" do
      viewer = stock_issue_user(business)
      _, result = draft!(central.id, actor: viewer)
      expect(result).not_to be_ok
    end
  end

  describe "the lifecycle keeps the selected warehouse" do
    let(:issue) do
      restrict_to_warehouses!(requester, central, annex)
      draft!(annex.id).first
    end

    def submit!(i = issue) = Inventory::StockIssueSubmission.new(stock_issue_id: i.id, actor: requester).call
    def approve!(i = issue) = Inventory::StockIssueApproval.new(stock_issue_id: i.id, actor: approver).approve!
    def confirm!(i = issue) = Inventory::StockIssueConfirmationService.new(stock_issue_id: i.id, actor: approver).call

    it "deducts from the selected warehouse only, at average cost, with the standard audit trail" do
      expect(submit!).to be_ok
      expect(approve!).to be_ok
      expect(confirm!).to be_ok

      expect([ on_hand(annex), on_hand(central), on_hand(nasr_wh) ]).to eq([ 28, 20, 10 ])
      movement = issue.reload.inventory_movements.sole
      expect(movement).to have_attributes(warehouse_id: annex.id, direction: "out", branch_id: nil)
      expect(movement.unit_cost.to_d).to eq(10)
      expect(AuditLog.for_auditable(issue).order(:id).map(&:action)).to eq(%w[create submit_for_approval approve confirm])
    end

    it "re-checks warehouse access at approval and at confirmation (access revoked in between)" do
      submit!
      restrict_to_warehouses!(approver, central) # approver cannot reach Annex
      expect(approve!.error).to eq(Inventory::WarehouseReach.message)
      expect(issue.reload).to be_pending_approval

      WarehouseAssignment.create!(user: approver, warehouse: annex)
      expect(approve!).to be_ok
      WarehouseAssignment.where(user: approver, warehouse: annex).delete_all
      expect(confirm!.error).to eq(Inventory::WarehouseReach.message)
      expect(issue.reload).to be_approved
      expect(issue.inventory_movements).to be_empty
    end

    it "re-checks the stored warehouse under lock at approval and at confirmation" do
      checked = []
      allow_any_instance_of(Inventory::IssueWarehouseReach).to receive(:verify_under_lock).and_wrap_original do |method, record|
        checked << record.warehouse_id
        method.call(record)
      end
      submit!
      approve!
      confirm!
      expect(checked).to eq([ annex.id, annex.id ])
      expect(issue.reload).to be_issued
    end

    it "refuses confirmation once the warehouse is inactive, deducting nothing" do
      submit!
      approve!
      annex.update_column(:status, "inactive")
      expect(confirm!.error).to eq(I18n.t("inventory.issue_warehouse.errors.inactive", warehouse: "Annex"))
      expect(on_hand(annex)).to eq(30)
    end

    it "lets an edit move a draft only to another authorized active warehouse, audited" do
      edit = ->(warehouse_id) do
        Inventory::StockIssueEditor.new(stock_issue_id: issue.id, actor: requester,
                                        attributes: { warehouse_id: warehouse_id }).call
      end
      expect(edit.call(nasr_wh.id)).not_to be_ok # not authorized
      expect(edit.call(closed.id)).not_to be_ok  # inactive
      expect(issue.reload.warehouse_id).to eq(annex.id)

      expect(edit.call(central.id)).to be_ok
      expect(issue.reload.warehouse_id).to eq(central.id)
      update = AuditLog.for_auditable(issue).where(action: "update").order(:id).last
      expect(update.changes_json["warehouse_id"]).to eq([ annex.id, central.id ])
    end

    it "ignores a submitted branch on edit" do
      Inventory::StockIssueEditor.new(stock_issue_id: issue.id, actor: requester, attributes: { branch_id: nasr.id, notes: "x" }).call
      expect(issue.reload).to have_attributes(branch_id: nil, notes: "x")
    end

    it "keeps cancellation and void tied to the issue's warehouse access" do
      outsider = stock_issue_user(business, :cancel_stock_issues, :void_stock_issues)
      restrict_to_warehouses!(outsider, central)
      expect(Inventory::StockIssueCancellation.new(stock_issue_id: issue.id, actor: outsider, reason: "x").call).not_to be_ok
      expect(issue.reload).to be_draft
    end
  end

  describe "historical issues" do
    # Recorded under earlier rules: a consuming branch chosen independently of
    # a central warehouse ("selected"), and an interim branch-warehouse issue.
    let!(:legacy) do
      i = business.stock_issues.build(warehouse: central, branch: nasr, issued_on: Date.current - 5, created_by: owner,
                                      warehouse_source: "selected")
      i.items.build(product: shampoo, quantity: 1)
      save_stock_issue_in_status!(i, :approved)
    end
    let!(:interim) do
      i = business.stock_issues.build(warehouse: nasr_wh, branch: nasr, issued_on: Date.current - 2, created_by: owner,
                                      warehouse_source: "branch_warehouse")
      i.items.build(product: shampoo, quantity: 1)
      save_stock_issue_in_status!(i, :approved)
    end

    it "finish with their original warehouse and keep their recorded branch attribution" do
      [ legacy, interim ].each do |issue|
        expect(Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: owner).call).to be_ok
        issue.reload
        expect(issue).to be_issued
        expect(issue.inventory_movements.pluck(:warehouse_id, :branch_id)).to eq([ [ issue.warehouse_id, nasr.id ] ])
      end
      expect(legacy.warehouse_source).to eq("selected")
      expect(interim.warehouse_source).to eq("branch_warehouse")
      expect([ on_hand(central), on_hand(nasr_wh) ]).to eq([ 19, 9 ])
    end

    it "are not rewritten by an edit that keeps their warehouse" do
      Inventory::StockIssueEditor.new(stock_issue_id: legacy.id, actor: owner, attributes: { notes: "checked" }).call
      expect(legacy.reload).to have_attributes(warehouse_id: central.id, branch_id: nasr.id, notes: "checked")
    end
  end

  describe "CSV import" do
    let(:rows) { [ { row_number: 2, "sku" => "SH-1", "quantity" => "1" } ] }

    def import(warehouse, user: requester) = Inventory::Imports::StockIssueImporter.new(business, rows, warehouse: warehouse, user: user).call

    it "accepts an authorized warehouse and submits for approval" do
      restrict_to_warehouses!(requester, central)
      result = import(central)
      expect(result.issue).to be_pending_approval
      expect(result.issue).to have_attributes(warehouse_id: central.id, branch_id: nil, warehouse_source: "selected")
    end

    it "refuses an unauthorized, inactive or foreign warehouse, writing nothing" do
      restrict_to_warehouses!(requester, central)
      [ annex, closed, foreign_wh ].each do |warehouse|
        expect { import(warehouse) }.to raise_error(Inventory::WarehouseReach::Denied)
      end
      expect(StockIssue.count).to eq(0)
    end

    it "has no branch input" do
      expect {
        Inventory::Imports::StockIssueImporter.new(business, rows, branch: nasr, user: requester)
      }.to raise_error(ArgumentError)
    end
  end
end
