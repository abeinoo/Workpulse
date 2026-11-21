require "rails_helper"
require "rake"

# inventory:legacy_central_settings_transfer — the preview runs inside a READ
# ONLY database transaction and lists every product's old -> destination
# values; APPLY needs one business, an actor of that business and the central
# warehouse id + count from this environment's preview.
#
# Non-transactional so the task's own READ ONLY transaction is a real one.
RSpec.describe "inventory:legacy_central_settings_transfer" do
  include_context "non-transactional database"

  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("inventory:legacy_central_settings_transfer") }

  let(:task)      { Rake::Task["inventory:legacy_central_settings_transfer"] }
  let!(:business) { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let!(:central)  { business.warehouses.create!(name: "Central", kind: "central") }
  let!(:moved)    { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1, low_stock_level: 5, reorder_quantity: 12.5,
                                                    receive_low_stock_notification: false) } # no total alert to lose
  let!(:held)     { business.products.create!(name: "Mask", sku: "MK-1", initial_cost_price: 1, average_cost_price: 1, low_stock_level: 2, reorder_level: 9) }

  before { task.reenable }

  def run(env = {})
    stub_const("ENV", ENV.to_h.merge(env.transform_values(&:to_s)))
    output = StringIO.new
    allow($stdout).to receive(:puts) { |*lines| output.puts(*lines) }
    begin
      task.invoke
    rescue SystemExit => e
      output.puts("EXIT #{e.status}")
    end
    output.string
  end

  it "previews read-only: central warehouse found, counts, old -> destination values per product" do
    out = run("BUSINESS_IDS" => business.id)
    expect(out).to include("[PREVIEW — READ ONLY]", "Business ##{business.id} — central warehouse: ##{central.id} Central",
                           "to_create=2", "legacy_alert_only=0",
                           "pending transfer=2 (of which left without any alert: 0) exceptions=0")
    expect(out).to match(/to_create\s+product=#{moved.id}\s+SH-1 \| legacy low=5\.0 reorder=12\.5 total_alert=0 .*-> new central row low=5\.0 reorder=12\.5/)
    expect(out).to match(/to_create\s+product=#{moved.id}\s+SH-1 .*\| alert none -> none$/) # alerts off: nothing to hand over
    expect(out).to match(/to_create\s+product=#{held.id}\s+MK-1 \| legacy low=2\.0 reorder=0\.0 total_alert=9 .*-> new central row low=2\.0 reorder=0\.0 .*\| alert total<=9 -> central<=2\.0$/)
    expect(ProductWarehouseSetting.count).to eq(0)
  end

  it "refuses APPLY without the guards, and with another environment's numbers; nothing written" do
    expect(run("APPLY" => "1", "BUSINESS_IDS" => business.id)).to include("EXIT 1")
    task.reenable
    expect(run("APPLY" => "1", "BUSINESS_IDS" => business.id, "ACTOR_ID" => owner.id, "EXPECT_CENTRAL_ID" => central.id + 99, "EXPECT_COUNT" => 2))
      .to include("[APPLY REFUSED: preview_mismatch] nothing was written", "EXIT 1")
    expect(ProductWarehouseSetting.count).to eq(0)
  end

  it "applies with this environment's numbers: exact values, audited as the actor" do
    out = run("APPLY" => "1", "BUSINESS_IDS" => business.id, "ACTOR_ID" => owner.id, "EXPECT_CENTRAL_ID" => central.id, "EXPECT_COUNT" => 2)
    expect(out).to include("[APPLIED] created 2 central row(s) as #{owner.id}", "matching=2", "to_create=0")
    expect(ProductWarehouseSetting.order(:product_id).pluck(:product_id, :warehouse_id, :low_stock_level, :reorder_quantity))
      .to eq([ [ moved.id, central.id, 5, 12.5 ], [ held.id, central.id, 2, 0 ] ])
    expect(AuditLog.where(action: "availability_add").pluck(:actor_id).uniq).to eq([ owner.id ])
  end
end
