require "rails_helper"
require "rake"

# Warehouse Architecture PR 4 — inventory:branch_warehouse_backfill is a dry run
# unless EXECUTE=1 exactly, shows only the actor's business, provisions only
# the listed branches, and fails loudly.
#
# Non-transactional: the backfill refuses to execute inside an open
# transaction (see branch_warehouse_backfill_execute_spec.rb).
RSpec.describe "inventory:branch_warehouse_backfill" do
  include_context "non-transactional database"

  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("inventory:branch_warehouse_backfill") }

  let(:task)       { Rake::Task["inventory:branch_warehouse_backfill"] }
  let!(:business)  { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let!(:legacy)    { business.warehouses.create!(name: "Main") }
  let!(:shubra)    { create(:branch, business: business, name: "Shubra", branch_type: "sales") }
  let!(:nasr)      { create(:branch, business: business, name: "Nasr", branch_type: "sales") }
  let!(:laundry)   { create(:branch, business: business, name: "Wash", branch_type: "laundry") }
  let!(:other)     { create(:business, name: "Unrelated Tenant Co") }
  let!(:other_hq)  { create(:branch, business: other, name: "Unrelated Secret Branch", branch_type: "sales") }

  before { task.reenable }

  def run(env)
    stub_const("ENV", ENV.to_h.merge(env.transform_values(&:to_s)))
    output = StringIO.new
    allow($stdout).to receive(:puts) { |*lines| output.puts(*lines) }
    task.invoke
    output.string
  end

  def base_env = { "ACTOR_ID" => owner.id, "APPROVED_BUSINESS_IDS" => business.id }

  it "is a dry run by default: prints the plan and writes nothing" do
    output = nil
    expect { output = run(base_env) }.not_to change { [ Warehouse.count, AuditLog.count ] }

    expect(output).to include("READY", "NOT_ELIGIBLE", "Shubra – المخزن", "DRY RUN — nothing was written")
    expect(legacy.reload.kind).to be_nil
  end

  [ "true", "0", "yes", "1 ", "TRUE", "" ].each do |value|
    it "stays a dry run for EXECUTE=#{value.inspect} (only the exact string \"1\" writes)" do
      output = nil
      expect { output = run(base_env.merge("BRANCH_IDS" => shubra.id, "EXECUTE" => value)) }
        .not_to change { [ Warehouse.count, AuditLog.count ] }
      expect(output).to include("DRY RUN — nothing was written")
    end
  end

  it "never prints another business's branches or name — even when that business is listed as approved" do
    output = run(base_env.merge("APPROVED_BUSINESS_IDS" => "#{business.id},#{other.id}"))

    expect(output).not_to include("Unrelated Secret Branch", "Unrelated Tenant Co", "branch=#{other_hq.id}")
    expect(output).to include("business ##{other.id}: outside the actor's business — not planned or shown")
  end

  it "provisions only the listed branches with EXECUTE=1" do
    output = run(base_env.merge("BRANCH_IDS" => shubra.id, "EXECUTE" => "1"))

    expect(output).to include("CREATED")
    expect(Warehouse.where(kind: "branch").pluck(:branch_id)).to eq([ shubra.id ])
    expect(Warehouse.where(branch_id: nasr.id)).to be_empty
  end

  it "exits non-zero when a listed branch fails, after reporting every branch" do
    expect { run(base_env.merge("BRANCH_IDS" => "#{laundry.id},#{shubra.id}", "EXECUTE" => "1")) }.to raise_error(SystemExit)

    expect(Warehouse.where(kind: "branch").pluck(:branch_id)).to eq([ shubra.id ])
  end

  it "refuses to execute without BRANCH_IDS" do
    expect { run(base_env.merge("EXECUTE" => "1")) }.to raise_error(KeyError)
    expect(Warehouse.where(kind: "branch")).to be_empty
  end

  it "refuses to execute for an actor whose business is not approved" do
    expect {
      run(base_env.merge("APPROVED_BUSINESS_IDS" => other.id, "BRANCH_IDS" => shubra.id, "EXECUTE" => "1"))
    }.to raise_error(SystemExit)
    expect(Warehouse.where(kind: "branch")).to be_empty
  end

  it "refuses an inactive actor, even for a dry run" do
    owner.update_column(:active, false)

    expect { run(base_env) }.to raise_error(SystemExit)
    expect(Warehouse.where(kind: "branch")).to be_empty
  end
end
