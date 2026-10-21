require "rails_helper"

# F-A5 — User#destroy never deletes employee history: each history association
# is dependent: :restrict_with_error, so any one row refuses the deletion on
# every path (controller, service, console) and leaves everything in place.
RSpec.describe User, "deletion guard (F-A5)" do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }

  it "guards exactly the approved history associations (and custody accounts)" do
    restricted = User.reflect_on_all_associations.select { |a| a.options[:dependent] == :restrict_with_error }.map(&:name)
    expect(restricted).to match_array(UserHistoryBuilders::USER_HISTORY.keys + [ :custody_accounts ])
  end

  UserHistoryBuilders::USER_HISTORY.each_key do |association|
    it "refuses to destroy a user with #{association} and keeps it" do
      create_user_history(association, employee)
      before_count = user_history_count(association, employee)
      expect(before_count).to be_positive

      expect(employee.destroy).to be(false)

      expect(User.exists?(employee.id)).to be(true)
      expect(user_history_count(association, employee)).to eq(before_count)
      expect(employee.errors.details[:base].map { |d| d[:record] }).to include(User.human_attribute_name(association).downcase)
    end
  end

  it "checks history before destroying shift assignments (attendance references them): a clean refusal, assignments kept" do
    record = create(:attendance_record, user: employee, business: business) # also builds its shift assignment
    assignment_id = record.shift_assignment_id

    expect { expect(employee.destroy).to be(false) }.not_to raise_error
    expect(ShiftAssignment.exists?(assignment_id)).to be(true)
  end

  it "still destroys a user without history, with their operational rows (shift and warehouse assignments)" do
    assignment = create(:shift_assignment, user: employee, branch: create(:branch, business: business),
                                           shift: create(:shift, :fixed_time, business: business))
    warehouse  = Warehouse.create!(business: business, name: "WH #{SecureRandom.hex(3)}")
    employee.assigned_warehouses << warehouse

    expect(employee.destroy).to be_truthy
    expect(User.exists?(employee.id)).to be(false)
    expect(ShiftAssignment.exists?(assignment.id)).to be(false)
    expect(WarehouseAssignment.where(user_id: employee.id)).to be_empty
  end
end
