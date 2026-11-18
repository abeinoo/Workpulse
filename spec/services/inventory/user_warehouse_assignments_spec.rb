require "rails_helper"

# Warehouse Architecture PR 5 (D7): every warehouse assignment created or
# removed through Inventory::UserWarehouseAssignments (the employee form's
# only write path, via OrganizationAccess::UserWarehouseAccess) is audited in
# the actor's name, in the same transaction as the change.
RSpec.describe Inventory::UserWarehouseAssignments do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:actor)   { create(:user, :owner, business: business) } # eager: its factory saves the business
  let(:employee) { create(:user, business: business) }
  let!(:main_wh)   { business.warehouses.create!(name: "Main") }
  let!(:second_wh) { business.warehouses.create!(name: "Second") }
  let!(:foreign)   { other.warehouses.create!(name: "Foreign") }

  def assign(ids, user: employee, by: actor) = described_class.assign(user: user, warehouse_ids: ids, actor: by)
  def audits = AuditLog.where(auditable_type: "WarehouseAssignment").order(:id)
  def assigned(user = employee) = WarehouseAssignment.where(user: user).order(:warehouse_id).pluck(:warehouse_id)

  it "audits a created assignment: actor, target user, warehouse, business, action and time" do
    freeze_time do
      expect { assign([ main_wh.id.to_s ]) }.to change(audits, :count).by(1)

      entry = audits.last
      assignment = WarehouseAssignment.find_by!(user: employee, warehouse: main_wh)
      expect(entry).to have_attributes(action: "create", actor_id: actor.id, business_id: business.id,
                                       auditable_id: assignment.id, created_at: Time.current)
      expect(entry.metadata).to eq("user_id" => employee.id, "warehouse_id" => main_wh.id, "business_id" => business.id)
    end
  end

  it "audits a removed assignment" do
    assign([ main_wh.id.to_s ])
    removed_id = WarehouseAssignment.find_by!(user: employee, warehouse: main_wh).id

    expect { assign([ "" ]) }.to change(audits, :count).by(1)
    expect(audits.last).to have_attributes(action: "destroy", actor_id: actor.id, auditable_id: removed_id)
    expect(audits.last.metadata).to include("user_id" => employee.id, "warehouse_id" => main_wh.id)
    expect(assigned).to be_empty
  end

  it "replaces the set: one entry per assignment removed and per assignment added, none for one kept" do
    assign([ main_wh.id.to_s ])

    expect { assign([ "", main_wh.id.to_s, second_wh.id.to_s ]) }.to change(audits, :count).by(1)
    expect(audits.last).to have_attributes(action: "create")
    expect(assigned).to eq([ main_wh.id, second_wh.id ])

    expect { assign([ second_wh.id.to_s ]) }.to change(audits, :count).by(1)
    expect(audits.last).to have_attributes(action: "destroy")
    expect(assigned).to eq([ second_wh.id ])
  end

  it "writes nothing when nothing changes" do
    assign([ main_wh.id.to_s ])

    expect { assign([ "", main_wh.id.to_s ]) }.not_to change { [ audits.count, WarehouseAssignment.count ] }
  end

  it "rejects another business's warehouse: no assignment, no audit entry, the existing set kept" do
    assign([ main_wh.id.to_s ])

    expect { assign([ second_wh.id.to_s, foreign.id.to_s ]) }
      .to raise_error(ActiveRecord::RecordInvalid)
      .and(not_change { [ audits.count, WarehouseAssignment.count ] })
    expect(assigned).to eq([ main_wh.id ])
  end

  it "raises RecordNotFound for an unknown warehouse id and changes nothing" do
    assign([ main_wh.id.to_s ])

    expect { assign([ (Warehouse.maximum(:id) + 1000).to_s ]) }
      .to raise_error(ActiveRecord::RecordNotFound)
      .and(not_change { [ audits.count, assigned ] })
  end

  it "rolls the audit entries back with the change when the surrounding transaction rolls back" do
    ActiveRecord::Base.transaction do
      assign([ main_wh.id.to_s ])
      raise ActiveRecord::Rollback
    end

    expect(audits).to be_empty
    expect(assigned).to be_empty
  end

  it "rolls the change back when its audit entry cannot be written (fail-closed)" do
    assign([ main_wh.id.to_s ])
    fail_audit_writes!

    expect { assign([ second_wh.id.to_s ]) }.to raise_error(AuditLoggable::AuditWriteFailed)
    expect(assigned).to eq([ main_wh.id ])
  end

  it "requires an explicit actor of the user's own business — never an implicit one" do
    expect { assign([ main_wh.id.to_s ], by: nil) }.to raise_error(ArgumentError, /actor is required/)
    expect { assign([ main_wh.id.to_s ], by: create(:user, :owner, business: other)) }.to raise_error(ArgumentError, /same|business/)
    expect(WarehouseAssignment.count).to eq(0)
  end

  describe "a new user (today's timing kept)" do
    def new_user = business.users.new(first_name: "New", last_name: "Hire", email: "new.hire@example.com")

    it "saves and audits the assignments with the user, not before" do
      user = new_user
      assign([ main_wh.id.to_s ], user: user)
      expect([ WarehouseAssignment.count, audits.count ]).to eq([ 0, 0 ])

      user.save!
      expect(assigned(user)).to eq([ main_wh.id ])
      expect(audits.sole).to have_attributes(action: "create", actor_id: actor.id)
      expect(audits.sole.metadata).to include("user_id" => user.id, "warehouse_id" => main_wh.id)
    end

    it "saves neither the user nor an assignment nor an audit entry when the user is invalid" do
      user = new_user
      user.last_name = ""
      assign([ main_wh.id.to_s ], user: user)

      expect(user.save).to be(false)
      expect([ WarehouseAssignment.count, audits.count ]).to eq([ 0, 0 ])
    end
  end
end
