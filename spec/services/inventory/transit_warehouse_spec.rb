require "rails_helper"

# Inventory::TransitWarehouse — exactly one system transit warehouse per
# business, created on demand, idempotently, audited.
RSpec.describe Inventory::TransitWarehouse do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  it "creates the business's transit warehouse once and returns it afterwards" do
    first = described_class.for!(business, actor: owner)
    expect(first).to be_persisted.and be_transit
    expect(described_class.for!(business, actor: owner)).to eq(first)
    expect(described_class.for!(business.id, actor: owner)).to eq(first)
    expect(Warehouse.transit.where(business: business).count).to eq(1)
  end

  it "keeps one per business" do
    other_business = create(:business)
    other_owner = create(:user, business: other_business)
    mine   = described_class.for!(business, actor: owner)
    theirs = described_class.for!(other_business, actor: other_owner)
    expect(mine).not_to eq(theirs)
    expect(described_class.find_for(other_business)).to eq(theirs)
  end

  it "finds without creating" do
    expect(described_class.find_for(business)).to be_nil
    expect(Warehouse.transit.count).to eq(0)
  end

  it "audits the creation (mandatory) and only the creation" do
    warehouse = described_class.for!(business, actor: owner)
    described_class.for!(business, actor: owner)
    entries = AuditLog.where(auditable: warehouse)
    expect(entries.pluck(:action)).to eq(%w[provision_transit_warehouse])
    expect(entries.first.actor).to eq(owner)
  end

  it "creates nothing when the audit entry cannot be written" do
    allow_any_instance_of(described_class).to receive(:log_audit!).and_raise(AuditLoggable::AuditWriteFailed)
    expect { described_class.for!(business, actor: owner) }.to raise_error(AuditLoggable::AuditWriteFailed)
    expect(described_class.find_for(business)).to be_nil
  end

  it "requires an actor of the same business" do
    expect { described_class.for!(business, actor: nil) }.to raise_error(ArgumentError)
    expect { described_class.for!(business, actor: create(:user)) }.to raise_error(ArgumentError)
  end

  it "returns the row a concurrent provisioner created first (lock re-check)" do
    calls = 0
    allow(described_class).to receive(:find_for).and_wrap_original do |original, *args|
      calls += 1
      if calls == 1 # this caller's first look: someone else wins the race right after it
        w = Warehouse.new(business: business, name: Warehouse::TRANSIT_NAME, kind: "transit", status: "active")
        w.system_provisioning = true
        w.save!
        next nil
      end
      original.call(*args)
    end
    winner = described_class.for!(business, actor: owner)
    expect(Warehouse.transit.where(business: business).count).to eq(1)
    expect(winner).to be_transit
  end

  it "falls back to the existing row when a duplicate is refused (name validation or unique index)" do
    existing = described_class.for!(business, actor: owner)
    allow(described_class).to receive(:find_for).and_wrap_original do |original, *args|
      @looked = (@looked || 0) + 1
      @looked <= 2 ? nil : original.call(*args) # both pre-checks miss -> insert -> unique violation -> re-read
    end
    expect(described_class.for!(business, actor: owner)).to eq(existing)
    expect(Warehouse.transit.where(business: business).count).to eq(1)
  end
end
