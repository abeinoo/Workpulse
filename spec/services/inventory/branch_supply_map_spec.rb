require "rails_helper"

RSpec.describe Inventory::BranchSupplyMap, type: :model do
  let(:business) { create(:business) }
  let(:admin)    { create(:user, :super_admin, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:north)    { business.warehouses.create!(name: "North") }
  let(:shubra)   { business.branches.create!(name: "Shubra", active: true) }
  let(:nasr)     { business.branches.create!(name: "Nasr", active: true) }
  let(:sahel)    { business.branches.create!(name: "Sahel", active: true) }
  let(:product)  { business.products.create!(name: "Dye", sku: "D-1", initial_cost_price: 5, average_cost_price: 5) }

  def receive(wh, qty = 50)
    r = business.goods_receipts.build(warehouse: wh, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 5)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def issue(wh, branch)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: Date.current)
    i.items.build(product: product, quantity: 1)
    approve_and_post_stock_issue(i).tap { |res| expect(res.ok?).to be(true) }
  end

  def link(branch, wh, active: true)
    Inventory::WarehouseSupplyAssigner.new(branch_id: branch.id, warehouse_id: wh.id, active: active, actor: admin).call
                                      .tap { |res| expect(res.ok?).to be(true) }
  end

  def map(**opts) = described_class.new(business, **opts)

  before { receive(main) && receive(north) }

  it "one warehouse → one branch (explicit)" do
    link(shubra, main)
    expect(map.links.map { |l| [ l.branch_id, l.warehouse_id, l.source ] }).to eq([ [ shubra.id, main.id, :explicit ] ])
    expect(map.shared_warehouse?(main.id)).to be(false)
  end

  it "one warehouse → multiple branches is shared" do
    [ shubra, nasr, sahel ].each { |b| link(b, main) }
    expect(map.branch_ids_for_warehouse(main.id)).to contain_exactly(shubra.id, nasr.id, sahel.id)
    expect(map.shared_warehouse?(main.id)).to be(true)
  end

  it "multiple warehouses → multiple branches" do
    link(shubra, main)
    link(nasr, north)
    link(sahel, north)
    expect(map.warehouse_ids_for(shubra.id)).to eq([ main.id ])
    expect(map.shared_warehouse?(main.id)).to be(false)
    expect(map.shared_warehouse?(north.id)).to be(true)
  end

  it "falls back to the inferred relationship for a branch without an explicit link, without saving it" do
    issue(main, nasr)
    links = map.links_for_branch(nasr.id)
    expect(links.map { |l| [ l.warehouse_id, l.source ] }).to eq([ [ main.id, :inferred ] ])
    expect(WarehouseBranchSupply.count).to eq(0)
  end

  it "a branch with no explicit link and no consumption is not linked" do
    expect(map.links_for_branch(sahel.id)).to be_empty
  end

  it "an explicit link takes priority over the inferred one" do
    issue(main, nasr)          # ledger says Main supplied Nasr
    link(nasr, north)          # admin says North supplies Nasr
    expect(map.links_for_branch(nasr.id).map { |l| [ l.warehouse_id, l.source ] }).to eq([ [ north.id, :explicit ] ])
    expect(map.shared_warehouse?(main.id)).to be(false)
  end

  it "an inactive explicit link falls back to inferred" do
    issue(main, nasr)
    link(nasr, north, active: false)
    expect(map.links_for_branch(nasr.id).map(&:source)).to eq([ :inferred ])
  end

  it "a warehouse-scoped map only shows links to those warehouses, and never re-infers a pinned branch" do
    issue(main, nasr)
    link(nasr, north)
    link(shubra, main)
    scoped = map(warehouse_ids: [ main.id ])
    expect(scoped.links.map { |l| [ l.branch_id, l.source ] }).to eq([ [ shubra.id, :explicit ] ])
  end

  it "is isolated per business" do
    other_business = create(:business)
    other_wh = other_business.warehouses.create!(name: "Other")
    other_branch = other_business.branches.create!(name: "Elsewhere", active: true)
    WarehouseBranchSupply.create!(business: other_business, warehouse: other_wh, branch: other_branch)
    link(shubra, main)
    expect(map.links.map(&:branch_id)).to eq([ shubra.id ])
  end
end

RSpec.describe Inventory::WarehouseSupplyAssigner, type: :model do
  let(:business) { create(:business) }
  let(:admin)    { create(:user, :super_admin, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:north)    { business.warehouses.create!(name: "North") }
  let(:branch)   { business.branches.create!(name: "Shubra", active: true) }

  def assign(wh, active: true, br: branch, actor: admin)
    described_class.new(branch_id: br.id, warehouse_id: wh.id, active: active, actor: actor).call
  end

  it "creates then changes the branch's single primary link, audit-logging both" do
    expect(assign(main).ok?).to be(true)
    expect(assign(north).ok?).to be(true)
    expect(WarehouseBranchSupply.where(branch: branch).count).to eq(1)
    supply = branch.reload.warehouse_supply
    expect([ supply.warehouse, supply.created_by, supply.updated_by ]).to eq([ north, admin, admin ])

    logs = AuditLog.for_auditable(supply).order(:id)
    expect(logs.map(&:action)).to eq(%w[create update])
    expect(logs.last.changes_json["warehouse_id"]).to eq([ main.id, north.id ])
  end

  it "deactivates without deleting" do
    assign(main)
    assign(main, active: "false")
    expect(branch.reload.warehouse_supply.active).to be(false)
  end

  it "refuses branches or warehouses from another business" do
    other = create(:business)
    foreign_wh = other.warehouses.create!(name: "Foreign")
    foreign_branch = other.branches.create!(name: "Foreign branch", active: true)
    expect(assign(foreign_wh).ok?).to be(false)
    expect(assign(main, br: foreign_branch).ok?).to be(false)
    expect(WarehouseBranchSupply.count).to eq(0)
  end

  it "the model rejects a cross-business link even when built directly" do
    other = create(:business)
    supply = WarehouseBranchSupply.new(business: business, branch: branch, warehouse: other.warehouses.create!(name: "X"))
    expect(supply).not_to be_valid
  end
end
