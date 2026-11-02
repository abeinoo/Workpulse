require "rails_helper"

RSpec.describe Inventory::StockIssueEditor, type: :model do
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:approver)  { create(:user, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let(:product2)  { business.products.create!(name: "Towel", sku: "TW-1", initial_cost_price: 5, average_cost_price: 5) }

  def receive_stock!(item, qty)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: item, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def pending_issue
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: requester)
    i.items.build(product: product, quantity: 2)
    i.save!
    Inventory::StockIssueSubmission.new(stock_issue_id: i.id, actor: requester).call
    i.reload
  end

  def edit(issue, attributes, actor: requester, lock_token: issue.lock_token)
    described_class.new(stock_issue_id: issue.id, actor: actor, attributes: attributes, lock_token: lock_token).call
  end

  def items_attrs(issue, quantity:, add: nil, remove: false)
    attrs = { "0" => { id: issue.items.first.id, product_id: product.id, quantity: quantity, _destroy: remove ? "1" : "0" } }
    attrs["1"] = { product_id: add.id, quantity: 3 } if add
    { items_attributes: attrs }
  end

  it "edits a pending issue's lines and returns it to draft, clearing the submission" do
    issue  = pending_issue
    result = edit(issue, items_attrs(issue, quantity: 4, add: product2))

    expect(result).to be_ok
    expect(result).to be_reopened
    issue.reload
    expect(issue).to be_draft
    expect(issue.submitted_by_id).to be_nil
    expect(issue.submitted_at).to be_nil
    expect(issue.items.map { |i| [ i.product_id, i.quantity.to_i ] }).to contain_exactly([ product.id, 4 ], [ product2.id, 3 ])
  end

  it "removes a line" do
    issue = pending_issue
    issue.items.create!(product: product2, quantity: 1)
    expect(edit(issue.reload, items_attrs(issue, quantity: 2, remove: true))).to be_ok
    expect(issue.reload.items.map(&:product_id)).to eq([ product2.id ])
  end

  it "audits the reopen and the line change, and keeps the earlier submission entry" do
    issue = pending_issue
    edit(issue, items_attrs(issue, quantity: 4))

    actions = AuditLog.for_auditable(issue).order(:id).pluck(:action)
    expect(actions).to include("submit_for_approval", "reopen_for_editing", "update")

    reopen = AuditLog.for_auditable(issue).find_by(action: "reopen_for_editing")
    expect(reopen.actor).to eq(requester)
    expect(reopen.changes_json["status"]).to eq(%w[pending_approval draft])

    update = AuditLog.for_auditable(issue).find_by(action: "update")
    before, after = update.changes_json["items"]
    expect(before.first["quantity"].to_d).to eq(2)
    expect(after.first["quantity"].to_d).to eq(4)
  end

  it "never creates inventory movements or changes stock" do
    receive_stock!(product, 10)
    issue = pending_issue
    expect { edit(issue, items_attrs(issue, quantity: 9)) }
      .not_to change(InventoryMovement, :count)
    expect(product.reload.current_stock).to eq(10)
  end

  it "requires resubmission and fresh approval: the edited draft can't be approved directly" do
    receive_stock!(product, 10)
    issue = pending_issue
    edit(issue, items_attrs(issue, quantity: 4))

    approval = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!
    expect(approval).not_to be_ok
    expect(issue.reload).to be_draft

    Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: requester).call
    expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!).to be_ok
    log = AuditLog.for_auditable(issue).find_by(action: "approve")
    expect(log.metadata["reserved"]).to eq(product.id.to_s => "4.0")
  end

  it "validates availability against the edited lines at approval" do
    receive_stock!(product, 5)
    issue = pending_issue
    edit(issue, items_attrs(issue, quantity: 8))
    Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: requester).call

    expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!).not_to be_ok
    expect(issue.reload).to be_pending_approval
  end

  it "is all-or-nothing: an invalid line leaves the issue pending and untouched" do
    issue  = pending_issue
    result = edit(issue, items_attrs(issue, quantity: 0, add: product2))

    expect(result).not_to be_ok
    issue.reload
    expect(issue).to be_pending_approval
    expect(issue.submitted_by).to eq(requester)
    expect(issue.items.map { |i| [ i.product_id, i.quantity.to_i ] }).to eq([ [ product.id, 2 ] ])
    expect(AuditLog.for_auditable(issue).where(action: %w[reopen_for_editing update])).to be_empty
  end

  it "refuses a stale lock token instead of overwriting newer changes" do
    issue = pending_issue
    stale = issue.lock_token
    travel 1.second do
      expect(edit(issue, items_attrs(issue, quantity: 3), lock_token: stale)).to be_ok
    end

    result = edit(issue, items_attrs(issue, quantity: 7), lock_token: stale)
    expect(result).not_to be_ok
    expect(result.error).to eq(I18n.t("inventory.stock_issues.errors.stale_edit"))
    expect(issue.reload.items.first.quantity.to_i).to eq(3)
  end

  it "advances the lock token on a line-only edit of a draft" do
    issue = pending_issue
    edit(issue, items_attrs(issue, quantity: 3))
    token = issue.reload.lock_token
    travel 1.second do
      edit(issue, items_attrs(issue, quantity: 4), lock_token: token)
    end
    expect(issue.reload.lock_token).not_to eq(token)
  end

  def reserved_qty(item = product)
    Inventory::StockAvailability.reserved_by(warehouse_ids: warehouse.id, product_ids: item.id)
                                .fetch([ warehouse.id, item.id ], 0).to_d
  end

  def approved_issue(quantity: 2)
    issue = pending_issue
    issue.items.first.update!(quantity: quantity) unless quantity == 2
    expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!).to be_ok
    issue.reload
  end

  describe "editing an approved issue" do
    before { receive_stock!(product, 10) }

    it "returns it to draft and clears the submission and approval" do
      issue  = approved_issue
      result = edit(issue, items_attrs(issue, quantity: 5))

      expect(result).to be_ok
      expect(result).to be_approval_revoked
      issue.reload
      expect(issue).to be_draft
      expect([ issue.approved_by_id, issue.approved_at, issue.submitted_by_id, issue.submitted_at ]).to all(be_nil)
      expect(issue.items.first.quantity.to_i).to eq(5)
    end

    it "releases the reservation in the same commit, and creates no movements" do
      issue = approved_issue
      expect(reserved_qty).to eq(2)

      expect { edit(issue, items_attrs(issue, quantity: 5)) }.not_to change(InventoryMovement, :count)
      expect(reserved_qty).to eq(0)
      expect(product.reload.current_stock).to eq(10)
    end

    it "frees the released stock for other issues" do
      issue = approved_issue(quantity: 8)
      other = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: requester)
      other.items.build(product: product, quantity: 5)
      other.save!
      Inventory::StockIssueSubmission.new(stock_issue_id: other.id, actor: requester).call
      approve_other = -> { Inventory::StockIssueApproval.new(stock_issue_id: other.id, actor: approver).approve! }

      expect(approve_other.call).not_to be_ok # 10 on hand, 8 reserved
      edit(issue, items_attrs(issue, quantity: 8))
      expect(approve_other.call).to be_ok
    end

    it "keeps the earlier approval in the audit history and records what was revoked" do
      issue = approved_issue
      approved_at = issue.approved_at
      edit(issue, items_attrs(issue, quantity: 5))

      approve_log = AuditLog.for_auditable(issue).find_by(action: "approve")
      expect(approve_log).to be_present
      expect(approve_log.actor).to eq(approver)

      reopen = AuditLog.for_auditable(issue).find_by(action: "reopen_for_editing")
      expect(reopen.changes_json["status"]).to eq(%w[approved draft])
      expect(reopen.metadata).to include("approval_revoked" => true, "previous_approved_by_id" => approver.id,
                                         "previous_submitted_by_id" => requester.id,
                                         "reservation_released" => { product.id.to_s => "2.0" })
      expect(Time.zone.parse(reopen.metadata["previous_approved_at"])).to be_within(1.second).of(approved_at)
    end

    it "can't be confirmed on the old approval" do
      issue = approved_issue
      edit(issue, items_attrs(issue, quantity: 5))

      confirm = Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call
      expect(confirm).not_to be_ok
      expect(issue.reload).to be_draft
      expect(InventoryMovement.where(source: issue)).to be_empty
    end

    it "is approved again only after resubmission, against the edited lines, then confirms them" do
      issue = approved_issue
      edit(issue, items_attrs(issue, quantity: 5, add: product2))
      receive_stock!(product2, 4)

      Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: requester).call
      expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!).to be_ok
      expect(AuditLog.for_auditable(issue).where(action: "approve").order(:id).last.metadata["reserved"])
        .to eq(product.id.to_s => "5.0", product2.id.to_s => "3.0")
      expect([ reserved_qty, reserved_qty(product2) ]).to eq([ 5, 3 ])

      expect(Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call).to be_ok
      expect(Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call).not_to be_ok
      expect([ product.reload.current_stock, product2.reload.current_stock ]).to eq([ 5, 1 ])
      expect(InventoryMovement.where(source: issue).count).to eq(2)
      expect([ reserved_qty, reserved_qty(product2) ]).to eq([ 0, 0 ])
    end

    it "rolls back completely on an invalid line: still approved, approval and reservation intact" do
      issue  = approved_issue
      result = edit(issue, items_attrs(issue, quantity: 0))

      expect(result).not_to be_ok
      expect(result.issue).to be_approved # re-rendered form shows the real state
      expect(result.issue.approved_by_id).to eq(approver.id)
      issue.reload
      expect(issue).to be_approved
      expect(issue.approved_by).to eq(approver)
      expect(issue.items.first.quantity.to_i).to eq(2)
      expect(reserved_qty).to eq(2)
      expect(AuditLog.for_auditable(issue).where(action: %w[reopen_for_editing update])).to be_empty
    end

    it "refuses a form opened while pending and saved after approval — never revokes an approval the editor didn't see" do
      issue = pending_issue
      stale = issue.lock_token # form opened here
      travel 1.second do
        Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!
      end

      result = edit(issue, items_attrs(issue, quantity: 5), lock_token: stale)
      expect(result.error).to eq(I18n.t("inventory.stock_issues.errors.stale_edit"))
      expect(issue.reload).to be_approved
      expect(reserved_qty).to eq(2)
    end
  end

  it "refuses to edit an issued, rejected, or cancelled issue" do
    %w[issued rejected cancelled].each do |status|
      i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: requester)
      i.items.build(product: product, quantity: 2)
      save_stock_issue_in_status!(i, status)

      result = edit(i.reload, items_attrs(i, quantity: 9))
      expect(result).not_to be_ok, status
      expect(result.error).to eq(I18n.t("inventory.stock_issues.errors.not_editable"))
      expect(i.reload.status).to eq(status)
      expect(i.items.first.quantity.to_i).to eq(2)
    end
  end

  describe "approval racing an edit (interleavings)" do
    it "approves the lines current at lock time, not lines loaded before an edit + resubmission" do
      receive_stock!(product, 10)
      issue    = pending_issue
      approval = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver)
      approval.send(:issue).items.load # approver's request read the old lines (qty 2)

      edit(issue, items_attrs(issue, quantity: 6))
      Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: requester).call

      expect(approval.approve!).to be_ok
      log = AuditLog.for_auditable(issue).find_by(action: "approve")
      expect(log.metadata["reserved"]).to eq(product.id.to_s => "6.0")
    end

    it "checks availability against the lines current at lock time" do
      receive_stock!(product, 5)
      issue    = pending_issue
      approval = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver)
      approval.send(:issue).items.load # old lines: qty 2, which would fit

      edit(issue, items_attrs(issue, quantity: 8))
      Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: requester).call

      expect(approval.approve!).not_to be_ok
      expect(issue.reload).to be_pending_approval
    end

    it "refuses self-approval when the approver resubmitted the issue after the approval pre-check" do
      receive_stock!(product, 10)
      issue    = pending_issue
      approval = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver)
      approval.send(:issue) # pre-check sees requester as submitter

      edit(issue, items_attrs(issue, quantity: 3), actor: approver)
      Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: approver).call

      result = approval.approve!
      expect(result).not_to be_ok
      expect(result.error).to eq(Approvals::SelfApproval.error_message)
      expect(issue.reload).to be_pending_approval
    end
  end

  describe "concurrency (separate DB connections)" do
    self.use_transactional_tests = false

    after do
      ids = StockIssue.where(business: business).select(:id)
      AuditLog.where(business: business).delete_all
      InventoryMovement.where(business: business).delete_all
      StockIssueItem.where(stock_issue_id: ids).delete_all
      StockIssue.where(business: business).delete_all
      GoodsReceiptItem.where(goods_receipt_id: GoodsReceipt.where(business: business).select(:id)).delete_all
      GoodsReceipt.where(business: business).delete_all
      ProductBarcode.where(product_id: Product.where(business: business).select(:id)).delete_all
      Product.where(business: business).delete_all
      Warehouse.where(business: business).delete_all
      Branch.where(business: business).delete_all
      User.where(business: business).delete_all
      Business.where(id: business.id).delete_all
    end

    # Runs `first` in a thread, waits until it signals (from inside its
    # transaction, holding the issue row lock) and then runs `second` on
    # another connection while `first` is still holding the lock.
    def while_holding(signal, first, second)
      t1 = Thread.new { ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) { first.call } }
      signal.pop
      t2 = Thread.new { ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) { second.call } }
      [ t1.value, t2.value ]
    end

    def race_edit_against_approval(issue, lock_token:)
      signal = Queue.new
      allow(Inventory::StockAvailability).to receive(:validate!).and_wrap_original do |original, *args|
        signal << true
        sleep 0.4
        original.call(*args)
      end
      while_holding(signal,
        -> { Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve! },
        -> { edit(issue, items_attrs(issue, quantity: 9), lock_token: lock_token) })
    end

    it "an edit from a form opened before an in-flight approval waits, then is refused as stale" do
      receive_stock!(product, 10)
      issue = pending_issue

      approved, edited = race_edit_against_approval(issue, lock_token: issue.lock_token)

      expect(approved).to be_ok
      expect(edited.error).to eq(I18n.t("inventory.stock_issues.errors.stale_edit"))
      issue.reload
      expect(issue).to be_approved
      expect(issue.items.map { |i| i.quantity.to_i }).to eq([ 2 ])
      expect(reserved_qty).to eq(2)
    end

    it "a token-less edit waits for an in-flight approval, then revokes it; no reservation is left behind" do
      receive_stock!(product, 10)
      issue = pending_issue

      approved, edited = race_edit_against_approval(issue, lock_token: nil)

      expect(approved).to be_ok
      expect(edited).to be_approval_revoked # it saw the committed approval under the lock
      issue.reload
      expect(issue).to be_draft
      expect(issue.approved_by_id).to be_nil
      expect(issue.items.map { |i| i.quantity.to_i }).to eq([ 9 ])
      expect(reserved_qty).to eq(0)
      expect(AuditLog.for_auditable(issue).find_by(action: "approve").metadata["reserved"]).to eq(product.id.to_s => "2.0")
    end

    it "an edit waits for an in-flight confirmation, then is refused; stock deducted once" do
      receive_stock!(product, 10)
      issue  = approved_issue
      signal = Queue.new
      allow(Inventory::StockIssuePoster).to receive(:new).and_wrap_original do |original, *args|
        signal << true
        sleep 0.4
        original.call(*args)
      end

      confirmed, edited = while_holding(signal,
        -> { Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call },
        -> { edit(issue, items_attrs(issue, quantity: 9)) })

      expect(confirmed).to be_ok
      expect(edited).not_to be_ok
      expect(edited.error).to eq(I18n.t("inventory.stock_issues.errors.not_editable"))
      expect(issue.reload).to be_issued
      expect(issue.items.first.quantity.to_i).to eq(2)
      expect(product.reload.current_stock).to eq(8)
    end

    it "a confirmation waits for an in-flight edit of an approved issue, then is refused; nothing deducted" do
      receive_stock!(product, 10)
      issue  = approved_issue
      signal = Queue.new
      allow_any_instance_of(StockIssue).to receive(:touch).and_wrap_original do |original, *args|
        signal << true
        sleep 0.4
        original.call(*args)
      end

      edited, confirmed = while_holding(signal,
        -> { edit(issue, items_attrs(issue, quantity: 9)) },
        -> { Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call })

      expect(edited).to be_ok
      expect(confirmed).not_to be_ok
      expect(issue.reload).to be_draft
      expect(InventoryMovement.where(source: issue)).to be_empty
      expect(product.reload.current_stock).to eq(10)
      expect(reserved_qty).to eq(0)
    end

    it "an approval waits for an in-flight edit, then is refused because the issue is back in draft" do
      receive_stock!(product, 10)
      issue  = pending_issue
      signal = Queue.new
      allow_any_instance_of(StockIssue).to receive(:touch).and_wrap_original do |original, *args|
        signal << true
        sleep 0.4
        original.call(*args)
      end

      edited, approved = while_holding(signal,
        -> { edit(issue, items_attrs(issue, quantity: 9)) },
        -> { Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve! })

      expect(edited).to be_ok
      expect(approved).not_to be_ok
      issue.reload
      expect(issue).to be_draft
      expect(issue.approved_by_id).to be_nil
      expect(issue.items.map { |i| i.quantity.to_i }).to eq([ 9 ])
    end

    it "two users saving the same form version: one wins, the other is refused as stale" do
      other  = create(:user, business: business)
      issue  = pending_issue
      token  = issue.lock_token
      signal = Queue.new
      allow_any_instance_of(StockIssue).to receive(:touch).and_wrap_original do |original, *args|
        signal << true
        sleep 0.4
        original.call(*args)
      end

      first, second = while_holding(signal,
        -> { edit(issue, items_attrs(issue, quantity: 3), lock_token: token) },
        -> { edit(issue, items_attrs(issue, quantity: 7), actor: other, lock_token: token) })

      expect(first).to be_ok
      expect(second).not_to be_ok
      expect(second.error).to eq(I18n.t("inventory.stock_issues.errors.stale_edit"))
      expect(issue.reload.items.map { |i| i.quantity.to_i }).to eq([ 3 ])
    end
  end

  it "detects a stale form when only lines changed through another path (import resolver / direct item write)" do
    issue = pending_issue
    edit(issue, items_attrs(issue, quantity: 3))
    token = issue.reload.lock_token

    travel 1.second do
      issue.items.create!(product: product2, quantity: 1) # no parent save
    end
    expect(issue.reload.lock_token).not_to eq(token)

    result = edit(issue, items_attrs(issue, quantity: 4), lock_token: token)
    expect(result.error).to eq(I18n.t("inventory.stock_issues.errors.stale_edit"))
  end

  it "refuses a product from another business" do
    other   = create(:business)
    foreign = other.products.create!(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1)
    issue   = pending_issue

    result = edit(issue, { items_attributes: { "0" => { product_id: foreign.id, quantity: 1 } } })
    expect(result).not_to be_ok
    expect(issue.reload.items.map(&:product_id)).to eq([ product.id ])
  end
end
