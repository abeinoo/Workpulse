require "rails_helper"

# Standard Stock Issue authorization enforced by the services themselves
# (console / job / any caller): one permission per operation AND access to the
# issue's warehouse (Inventory::IssueWarehouseReach), the submitter-only
# self-approval rule from the Standard Stock Issue setting, and mandatory
# cancel / void audit entries.
RSpec.describe "Stock Issue service-level authorization" do
  let(:business)  { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let!(:main)     { branch_warehouse_for(branch, name: "Main") } # Nasr City's own warehouse
  let!(:other_wh) { business.warehouses.create!(name: "Other") }
  let!(:branch)   { business.branches.create!(name: "Nasr City", active: true) }
  let!(:far)      { business.branches.create!(name: "Maadi", active: true) }
  let!(:far_wh)   { branch_warehouse_for(far) }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  let(:creator)   { stock_issue_user(business, :create_stock_issues) }
  # Everyone acts on issues of their own branches (branch visibility).
  let(:approver)  { stock_issue_user(business, :approve_stock_issues) }
  let(:confirmer) { stock_issue_user(business, :confirm_stock_issues) }
  let(:canceller) { stock_issue_user(business, :cancel_stock_issues) }
  let(:voider)    { stock_issue_user(business, :void_stock_issues) }
  let(:nobody)    { stock_issue_user(business) }
  let(:denied)    { Inventory::StockIssueAuthorization.message }

  before do
    receipt = business.goods_receipts.build(warehouse: main, received_on: Date.current)
    receipt.items.build(product: product, quantity: 20, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(receipt).call
  end

  def new_issue(warehouse: main, issue_branch: branch)
    business.stock_issues.build(warehouse: warehouse, branch: issue_branch, issued_on: Date.current).tap do |i|
      i.items.build(product: product, quantity: 1)
    end
  end

  def draft(by: creator) = new_issue.tap { |i| expect(Inventory::StockIssueDraftService.new(i, actor: by).call).to be_ok }

  def submitted(by: creator)
    issue = draft(by: by)
    expect(Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: by).call).to be_ok
    issue.reload
  end

  def approve(issue, by:) = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: by).approve!
  def confirm(issue, by:) = Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: by).call

  def issued
    issue = submitted
    expect(approve(issue, by: approver)).to be_ok
    expect(confirm(issue, by: confirmer)).to be_ok
    issue.reload
  end

  def set_self_approval!(value)
    expect(OrganizationAccess::StockIssueWorkflowSettings.call(business: business, actor: owner, self_approval: value,
                                                               quick_issue_enabled: true)).to be_ok
  end

  describe "each operation needs its own permission" do
    it "create / submit / edit / delete a draft: create_stock_issues only" do
      [ approver, confirmer, canceller, voider, nobody ].each do |user|
        issue = new_issue
        expect(Inventory::StockIssueDraftService.new(issue, actor: user).call).not_to be_ok
        expect(issue.errors[:base]).to include(denied)
      end

      issue = draft
      expect(Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: approver).call.error).to eq(denied)
      expect(Inventory::StockIssueEditor.new(stock_issue_id: issue.id, actor: approver, attributes: {}).call.error).to eq(denied)
      expect(Inventory::StockIssueDraftDeletion.new(stock_issue_id: issue.id, actor: approver).call.error).to eq(denied)
      expect(issue.reload).to be_draft
    end

    it "approve / reject: approve_stock_issues only" do
      issue = submitted
      [ creator, confirmer, canceller, voider ].each do |user|
        expect(approve(issue, by: user).error).to eq(denied)
        expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: user).reject!(reason: "x").error).to eq(denied)
      end
      expect(approve(issue, by: approver)).to be_ok
    end

    it "confirm: confirm_stock_issues only — and approval stays mandatory" do
      issue = submitted
      expect(confirm(issue, by: confirmer).error).to eq(I18n.t("inventory.stock_issues.errors.not_approved"))
      expect(approve(issue, by: approver)).to be_ok
      [ creator, approver, canceller, voider ].each { |user| expect(confirm(issue, by: user).error).to eq(denied) }
      expect { expect(confirm(issue, by: confirmer)).to be_ok }.to change(InventoryMovement, :count).by(1)
    end

    it "lets the approver confirm what they approved when they hold both" do
      both  = stock_issue_user(business, :approve_stock_issues, :confirm_stock_issues)
      issue = submitted
      expect(approve(issue, by: both)).to be_ok
      expect(confirm(issue, by: both)).to be_ok
    end

    it "cancel: cancel_stock_issues only (the creator may cancel when they hold it)" do
      issue = draft
      [ creator, approver, voider ].each do |user|
        expect(Inventory::StockIssueCancellation.new(stock_issue_id: issue.id, actor: user, reason: "x").call.error).to eq(denied)
      end
      creator_who_cancels = stock_issue_user(business, :create_stock_issues, :cancel_stock_issues)
      own = draft(by: creator_who_cancels)
      expect(Inventory::StockIssueCancellation.new(stock_issue_id: own.id, actor: creator_who_cancels, reason: "not needed").call)
        .to be_ok
    end

    it "void: void_stock_issues only, posted issues only" do
      posted = issued
      [ creator, canceller, approver, confirmer ].each do |user|
        expect { Inventory::DocumentVoider.new(posted, user: user, reason: "x").call }.not_to change(InventoryMovement, :count)
        expect(posted.errors[:base]).to include(denied)
        posted.errors.clear
      end
      expect(Inventory::DocumentVoider.new(posted.reload, user: voider, reason: "wrong branch").call).to be_ok
      expect(posted.reload.voided_at).to be_present
    end

    it "manage_stock_issues grants nothing; manage_inventory is still honoured (transition)" do
      legacy = business.permission_roles.create!(name: "Legacy", permissions: %w[view_inventory manage_stock_issues])
      legacy_user = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, legacy.id) }
      expect(Inventory::StockIssueDraftService.new(new_issue, actor: legacy_user).call).not_to be_ok

      umbrella = business.permission_roles.create!(name: "Umbrella", permissions: %w[view_inventory manage_inventory])
      umbrella_user = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, umbrella.id) }
      expect(Inventory::StockIssueDraftService.new(new_issue, actor: umbrella_user).call).to be_ok
    end
  end

  describe "mandatory cancel / void audit entries" do
    def fail_audit_for(action)
      allow(AuditLog).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
        raise ActiveRecord::RecordInvalid, AuditLog.new if kwargs[:action] == action

        original.call(*args, **kwargs)
      end
    end

    it "rolls a cancellation back when its audit entry cannot be written" do
      issue = submitted
      expect(approve(issue, by: approver)).to be_ok
      fail_audit_for("cancel")

      result = Inventory::StockIssueCancellation.new(stock_issue_id: issue.id, actor: canceller, reason: "no").call
      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("inventory.stock_issues.errors.audit_failed"))
      expect(issue.reload).to be_approved
      expect(Inventory::StockAvailability.reserved_items.count).to be_positive
    end

    it "rolls a void back — no reversal movement — when its audit entry cannot be written" do
      posted = issued
      fail_audit_for("void")

      expect { expect(Inventory::DocumentVoider.new(posted, user: voider, reason: "x").call).not_to be_ok }
        .not_to change(InventoryMovement, :count)
      expect(posted.reload.voided_at).to be_nil
      expect(posted.errors.details[:base].map { |d| d[:error] }).to include(:void_audit_failed)
    end

    it "requires a reason for both" do
      expect(Inventory::StockIssueCancellation.new(stock_issue_id: draft.id, actor: canceller, reason: " ").call).not_to be_ok
      expect(Inventory::DocumentVoider.new(issued, user: voider, reason: "").call).not_to be_ok
    end
  end

  describe "draft deletion" do
    it "deletes a draft without a reason or an extra audit entry" do
      issue = draft
      expect { expect(Inventory::StockIssueDraftDeletion.new(stock_issue_id: issue.id, actor: creator).call).to be_ok }
        .to change(StockIssue, :count).by(-1).and not_change(AuditLog, :count)
    end

    it "refuses anything but a draft" do
      issue = submitted
      expect(Inventory::StockIssueDraftDeletion.new(stock_issue_id: issue.id, actor: creator).call).not_to be_ok
      expect(StockIssue.exists?(issue.id)).to be true
    end
  end

  describe "self-approval (Standard Stock Issue setting)" do
    let(:maker) { stock_issue_user(business, :create_stock_issues, :approve_stock_issues) }

    it "forbidden (default): the submitter may not approve or reject their own submission" do
      issue = submitted(by: maker)
      expect(approve(issue, by: maker).error).to eq(Approvals::SelfApproval.error_message)
      expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: maker).reject!(reason: "x").error)
        .to eq(Approvals::SelfApproval.error_message)
    end

    it "forbidden: editing does not block the editor — only the current submitter is compared" do
      issue = submitted(by: creator)
      # maker edits (reopens to draft); creator resubmits; maker may approve.
      expect(Inventory::StockIssueEditor.new(stock_issue_id: issue.id, actor: maker,
                                             attributes: { notes: "edited" }).call).to be_ok
      expect(Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: creator).call).to be_ok
      expect(approve(issue.reload, by: maker)).to be_ok
    end

    it "allowed: the submitter may approve their own submission" do
      set_self_approval!("allowed")
      expect(approve(submitted(by: maker), by: maker)).to be_ok
    end

    it "the owner is always exempt" do
      issue = business.stock_issues.build(warehouse: main, branch: branch, issued_on: Date.current, created_by: owner)
      issue.items.build(product: product, quantity: 1)
      issue.save!
      expect(Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: owner).call).to be_ok
      expect(approve(issue, by: owner)).to be_ok
    end

    it "records the setting on the approval entry" do
      issue = submitted
      approve(issue, by: approver)
      expect(AuditLog.for_auditable(issue).find_by(action: "approve").metadata["self_approval"]).to eq("forbidden")
    end
  end

  describe "warehouse access (independent of permissions)" do
    it "refuses an unreachable warehouse even with every permission" do
      WarehouseAssignment.create!(user: creator, warehouse: other_wh)
      issue = new_issue(warehouse: main)
      expect(Inventory::StockIssueDraftService.new(issue, actor: creator).call).not_to be_ok
      expect(issue.errors[:base]).to include(I18n.t("inventory.issue_warehouse.errors.not_allowed"))
    end

    it "takes no consuming branch from the caller: the branch is derived from the warehouse, also on edit" do
      issue = new_issue(issue_branch: far) # a submitted branch other than Main's
      expect(Inventory::StockIssueDraftService.new(issue, actor: creator).call).to be_ok
      expect(issue.reload.branch).to eq(branch)

      result = Inventory::StockIssueEditor.new(stock_issue_id: issue.id, actor: creator, attributes: { branch_id: far.id }).call
      expect(result).to be_ok
      expect(issue.reload.branch).to eq(branch)
    end

    it "refuses an import to a warehouse outside the importer's reach" do
      WarehouseAssignment.create!(user: creator, warehouse: other_wh)
      importer = Inventory::Imports::StockIssueImporter.new(business, [], warehouse: far_wh, user: creator)
      expect { importer.call }.to raise_error(Inventory::WarehouseReach::Denied)
    end

    it "lets the owner use any active warehouse of the business" do
      issue = new_issue(warehouse: far_wh, issue_branch: nil)
      expect(Inventory::StockIssueDraftService.new(issue, actor: owner).call).to be_ok
      expect(issue.reload.branch).to eq(far)
    end

    it "does not gate on the attributed branch's status (only the warehouse's)" do
      far.update_column(:active, false)
      issue = new_issue(warehouse: far_wh, issue_branch: nil)
      expect(Inventory::StockIssueDraftService.new(issue, actor: creator).call).to be_ok
    end
  end
end
