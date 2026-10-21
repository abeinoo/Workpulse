require "rails_helper"

# Batch W — warehouse access write boundary: the Organization & Access contract
# OrganizationAccess::UserWarehouseAccess and its Inventory & Purchasing
# implementation Inventory::UserWarehouseAssignments (today's ids-writer
# behaviour, unchanged). The employee-form behaviour stays pinned by
# spec/characterization/organization_access/user_warehouse_access_spec.rb.
RSpec.describe OrganizationAccess::UserWarehouseAccess do
  let(:business)   { create(:business) }
  let(:user)       { create(:user, business: business) }
  let(:main_wh)    { Warehouse.create!(business: business, name: "Main") }
  let(:second_wh)  { Warehouse.create!(business: business, name: "Second") }

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  describe "registration" do
    it "has the Inventory & Purchasing implementation registered at boot" do
      expect(described_class.handler).to equal(Inventory::UserWarehouseAssignments)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      expect { described_class.register(Module.new) }.to raise_error(ArgumentError, /assign/)
      expect(described_class.handler).to equal(Inventory::UserWarehouseAssignments)
    end

    it "raises NotRegistered instead of silently dropping access when no handler is registered" do
      with_handler(nil) do
        expect { described_class.assign(user: user, warehouse_ids: [ main_wh.id ]) }.to raise_error(described_class::NotRegistered)
      end
    end
  end

  describe "dispatch" do
    it "passes the user and ids to the handler and returns its result" do
      handler = double("handler", assign: :assigned)

      with_handler(handler) { expect(described_class.assign(user: user, warehouse_ids: [ "1" ])).to eq(:assigned) }
      expect(handler).to have_received(:assign).with(user: user, warehouse_ids: [ "1" ])
    end
  end

  describe "Inventory::UserWarehouseAssignments (today's timing)" do
    it "replaces a persisted user's assignments immediately, before any save" do
      user.assigned_warehouses << main_wh

      described_class.assign(user: user, warehouse_ids: [ "", second_wh.id.to_s ])

      expect(WarehouseAssignment.where(user: user).pluck(:warehouse_id)).to eq([ second_wh.id ])
    end

    it "saves a new user's assignments with the user" do
      new_user = business.users.new(first_name: "New", last_name: "Hire", email: "new.hire@example.com")

      described_class.assign(user: new_user, warehouse_ids: [ main_wh.id.to_s ])
      expect(WarehouseAssignment.count).to eq(0)

      new_user.save!
      expect(new_user.reload.assigned_warehouses).to eq([ main_wh ])
    end

    it "raises RecordInvalid for another business's warehouse" do
      foreign = Warehouse.create!(business: create(:business), name: "Foreign")

      expect { described_class.assign(user: user, warehouse_ids: [ foreign.id.to_s ]) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
