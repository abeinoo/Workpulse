require "rails_helper"

# Warehouse Architecture — PR 4: Inventory::BranchWarehouseBackfill#execute.
#
# Non-transactional: #execute refuses to run inside an open transaction (each
# branch must get its own, real transaction), and the usual transactional test
# wrapper is exactly such a transaction. The shared context refuses to start
# unless the test database is empty and truncates every table afterwards.
RSpec.describe Inventory::BranchWarehouseBackfill, "#execute" do
  include_context "non-transactional database"

  let!(:business)  { create(:business, name: "Gedo Salon") }
  let!(:demo)      { create(:business, name: "Al-Noor Group") }
  let!(:owner)     { create(:user, :owner, business: business) }
  let!(:legacy)    { business.warehouses.create!(name: "المخزن الرئيسي") } # kind NULL, as in the real data
  let!(:shubra)    { create(:branch, business: business, name: "صالون جدو - شارع شبرا", branch_type: "sales") }
  let!(:bulaq)     { create(:branch, business: business, name: "صالون جدو - الترعة البولاقية", branch_type: "sales") }
  let!(:nasr)      { create(:branch, business: business, name: "صالون جدو - مدينة نصر", branch_type: "sales") }
  let!(:laundry)   { create(:branch, business: business, name: "دراي كلين", branch_type: "laundry") }
  let!(:riyadh)    { create(:branch, business: demo, name: "Riyadh HQ", branch_type: "sales") }
  let!(:jeddah)    { create(:branch, business: demo, name: "Jeddah Branch", branch_type: "sales") }
  let!(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 5) }

  before do
    InventoryMovement.create!(business: business, product: product, warehouse: legacy, direction: :in,
                              reason: :opening_balance, quantity: 20, unit_cost: 5, occurred_on: Date.new(2026, 1, 1))
    InventoryMovement.create!(business: business, product: product, warehouse: legacy, direction: :out,
                              reason: :adjustment, quantity: 3, unit_cost: 5, occurred_on: Date.new(2026, 1, 2))
    business.stock_issues.create!(warehouse: legacy, branch: shubra, issued_on: Date.new(2026, 1, 3))
  end

  let(:approved) { [ business.id ] }
  def execute(ids, actor: owner) = described_class.new(actor: actor, approved_business_ids: approved).execute(branch_ids: ids)
  def backfill_audits = AuditLog.where(auditable_type: "Warehouse", action: "create").select { |a| a.metadata["source"] == "branch_backfill" }
  def error_for(key) = I18n.t("inventory.warehouses.backfill.errors.#{key}")

  # Everything the backfill must never change.
  def history
    {
      warehouses: Warehouse.where.not(kind: "branch").or(Warehouse.where(kind: nil)).order(:id)
                           .pluck(:id, :business_id, :name, :kind, :branch_id, :status, :updated_at),
      movements:  InventoryMovement.order(:id).pluck(:id, :warehouse_id, :product_id, :direction, :reason, :quantity, :unit_cost, :branch_id),
      issues:     StockIssue.order(:id).pluck(:id, :warehouse_id, :branch_id, :status, :updated_at),
      receipts:   GoodsReceipt.order(:id).pluck(:id, :warehouse_id, :updated_at),
      counts:     StockCount.order(:id).pluck(:id, :warehouse_id, :updated_at),
      adjustments: StockAdjustment.order(:id).pluck(:id, :warehouse_id, :updated_at),
      transfers:  StockTransfer.order(:id).pluck(:id, :source_warehouse_id, :destination_warehouse_id),
      on_hand:    product.stock_in(legacy)
    }
  end

  it "creates one empty branch warehouse per READY branch, audited as branch_backfill by the actor, changing nothing else" do
    before = history
    outcomes = execute([ shubra.id, bulaq.id, nasr.id ])

    expect(outcomes.map(&:status)).to eq(%w[CREATED CREATED CREATED])
    [ shubra, bulaq, nasr ].zip(outcomes).each do |branch, outcome|
      warehouse = Warehouse.find(outcome.warehouse_id)
      expect(warehouse).to have_attributes(kind: "branch", branch_id: branch.id, business_id: business.id,
                                           name: "#{branch.name} – المخزن", status: "active")
      expect(InventoryMovement.where(warehouse_id: warehouse.id)).to be_empty
      expect(product.stock_in(warehouse)).to eq(0)
    end
    expect(backfill_audits.size).to eq(3)
    expect(backfill_audits.map(&:actor_id).uniq).to eq([ owner.id ])

    expect(history).to eq(before)
    expect(legacy.reload.kind).to be_nil # never classified
    expect(Warehouse.where(branch_id: laundry.id)).to be_empty
    expect(Warehouse.where(business_id: demo.id)).to be_empty
  end

  it "is idempotent: a re-run creates nothing and writes no audit entry" do
    first = execute([ shubra.id, bulaq.id, nasr.id ]).map(&:warehouse_id)

    expect { expect(execute([ shubra.id, bulaq.id, nasr.id ]).map(&:status)).to eq(%w[ALREADY_PROVISIONED] * 3) }
      .not_to change { [ Warehouse.count, AuditLog.count ] }
    expect(Warehouse.where(branch_id: [ shubra.id, bulaq.id, nasr.id ]).pluck(:id)).to match_array(first)
  end

  it "fails — never skips silently — every listed branch that is not READY, and still provisions the rest" do
    nasr.update_column(:active, false)
    business.warehouses.create!(name: "صالون جدو - الترعة البولاقية – المخزن", kind: "central")

    outcomes = execute([ laundry.id, bulaq.id, nasr.id, shubra.id ]).index_by(&:branch_id)

    expect(outcomes[laundry.id]).to have_attributes(status: "FAILED", reason: "NOT_ELIGIBLE: not a sales branch (laundry)")
    expect(outcomes[bulaq.id].status).to eq("FAILED")
    expect(outcomes[bulaq.id].reason).to start_with("NAME_COLLISION")
    expect(outcomes[nasr.id]).to have_attributes(status: "FAILED", reason: "REQUIRES_MANUAL_REVIEW: inactive sales branch")
    expect(outcomes[shubra.id].status).to eq("CREATED")
    expect(Warehouse.where(kind: "branch").pluck(:branch_id)).to eq([ shubra.id ])
  end

  it "rolls back only the failing branch (its warehouse and audit entry) and reports it" do
    fail_audit_writes!(:create, skip: 1) # the first warehouse audit is written, the next ones fail

    outcomes = execute([ shubra.id, bulaq.id, nasr.id ])

    expect(outcomes.map(&:status)).to eq(%w[CREATED FAILED FAILED])
    expect(outcomes.last.reason).to eq(I18n.t("inventory.warehouses.errors.audit_failed"))
    expect(Warehouse.where(kind: "branch").pluck(:branch_id)).to eq([ shubra.id ])
    expect(backfill_audits.size).to eq(1)
  end

  it "commits each branch in its own transaction: a later failure never undoes an earlier branch" do
    fail_audit_writes!(:create, skip: 1)
    execute([ shubra.id, bulaq.id ])

    # Seen from a fresh connection: the first branch's warehouse is committed.
    committed = Thread.new { ActiveRecord::Base.connection_pool.with_connection { Warehouse.where(kind: "branch").pluck(:branch_id) } }.value
    expect(committed).to eq([ shubra.id ])
  end

  it "is refused inside an open transaction, before any write — every branch FAILED with the reason" do
    writes = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE|SELECT .* FOR )/i)
    end
    outcomes = ActiveRecord::Base.transaction { execute([ shubra.id, bulaq.id ]) }
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(outcomes.map { |o| [ o.status, o.reason ] }).to eq([ [ "FAILED", error_for(:transaction_open) ] ] * 2)
    expect(writes).to be_empty
    expect(Warehouse.where(kind: "branch")).to be_empty
  end

  it "is refused inside a non-joinable outer transaction too" do
    outcomes = ActiveRecord::Base.transaction(joinable: false) { execute([ shubra.id ]) }

    expect(outcomes.sole).to have_attributes(status: "FAILED", reason: error_for(:transaction_open))
    expect(Warehouse.where(kind: "branch")).to be_empty
  end

  it "refuses an inactive actor before any branch: no warehouse, no audit entry" do
    owner.update_column(:active, false)

    outcomes = nil
    expect { outcomes = execute([ shubra.id, bulaq.id, nasr.id ]) }.not_to change { [ Warehouse.count, AuditLog.count ] }
    expect(outcomes.map { |o| [ o.status, o.reason ] }).to eq([ [ "FAILED", error_for(:inactive_actor) ] ] * 3)
  end

  it "cannot reach another business's branches (business isolation)" do
    outcomes = execute([ riyadh.id, jeddah.id ])

    expect(outcomes.map(&:status)).to eq(%w[FAILED FAILED])
    expect(outcomes.map(&:reason).uniq).to eq([ "branch not found in the actor's business" ])
    expect(Warehouse.where(business_id: demo.id)).to be_empty
  end

  it "refuses an actor without manage_branches" do
    clerk = user_with_stock_permissions(business, :view_inventory)

    outcomes = execute([ shubra.id ], actor: clerk)
    expect(outcomes.sole).to have_attributes(status: "FAILED", reason: "not authorized (manage_branches)")
    expect(Warehouse.where(kind: "branch")).to be_empty
  end

  it "does not provision a business that is not approved, even for its own actor" do
    demo_owner = create(:user, :owner, business: demo)

    outcome = execute([ riyadh.id ], actor: demo_owner).sole
    expect(outcome).to have_attributes(status: "FAILED", reason: "REQUIRES_MANUAL_REVIEW: business not approved for this backfill")
    expect(Warehouse.where(business_id: demo.id)).to be_empty
  end
end
