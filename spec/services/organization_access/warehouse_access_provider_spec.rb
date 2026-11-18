require "rails_helper"

# Warehouse Architecture PR 5 (Phase 2): the Organization & Access contract
# OrganizationAccess::WarehouseAccessProvider — registration and delegation,
# following OrganizationAccess::MembershipProvider.
RSpec.describe OrganizationAccess::WarehouseAccessProvider do
  around do |example|
    registered = described_class.instance_variable_get(:@provider)
    example.run
  ensure
    described_class.instance_variable_set(:@provider, registered)
  end

  it "is registered with the Inventory implementation at boot" do
    expect(described_class.provider).to equal(Inventory::WarehouseAccess)
  end

  it "delegates warehouse_ids_for to the registered provider" do
    user = build_stubbed(:user)
    fake = Module.new { def self.warehouse_ids_for(user) = [ user.id, 42 ] }
    described_class.register(fake)

    expect(described_class.warehouse_ids_for(user)).to eq([ user.id, 42 ])
  end

  it "refuses a provider that does not implement the contract" do
    expect { described_class.register(Module.new) }.to raise_error(ArgumentError, /warehouse_ids_for/)
  end

  it "raises — never resolves to every warehouse — when no provider is registered" do
    described_class.instance_variable_set(:@provider, nil)

    expect { described_class.warehouse_ids_for(build_stubbed(:user)) }
      .to raise_error(described_class::NotRegistered)
  end
end
