require "rails_helper"

# Floating employees and authorization: a floating assignment creates no branch
# membership, so a branch manager does not see a floating employee — not even
# their punches at that manager's branch — while business-wide viewers do, and an
# area manager's own access still comes from branches.area_manager_id alone,
# whether or not the area manager is floating.
RSpec.describe "Floating employee visibility" do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:branch_c) { create(:branch, business: business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }
  let(:device_a) { create(:biometric_device, business: business, branch: branch_a) }

  let(:viewer_role) { create(:permission_role, business: business, permissions: %w[view_attendance view_employees]) }

  def user_with(role) = create(:user, business: business, permission_role: role)

  let(:floating_employee) { create(:user, business: business, allow_biometric_attendance: true) }
  let(:branch_employee)   { create(:user, business: business) }
  let(:branch_manager)    { user_with(viewer_role).tap { |u| branch_a.update!(branch_manager: u) } }
  let(:business_viewer) do
    user_with(create(:permission_role, business: business, permissions: %w[view_attendance view_employees],
                                       permission_scopes: { "view_attendance" => "business" }))
  end

  before do
    create(:shift_assignment, :floating, user: floating_employee, shift: shift)
    regular = create(:shift_assignment, user: branch_employee, shift: shift, branch: branch_a)
    # The floating employee punches at branch A's device.
    Attendance::PunchService.call(employee: floating_employee, punched_at: 2.hours.ago, business: business, device: device_a)
    create(:attendance_record, user: branch_employee, branch: branch_a, shift_assignment: regular, work_date: Date.current - 1)
  end

  def visible_attendance_users(viewer)
    Pundit.policy_scope!(viewer, AttendanceRecord).distinct.pluck(:user_id)
  end

  def visible_punch_log_employees(viewer)
    Pundit.policy_scope!(viewer, BiometricPunchLog).distinct.pluck(:employee_id)
  end

  it "records the floating employee's punch at branch A with branch A as its actual branch" do
    expect(BiometricPunchLog.find_by!(employee: floating_employee).branch_id).to eq(branch_a.id)
  end

  describe "a branch manager of the branch the floating employee punched at" do
    it "sees their own branch's employee but not the floating employee" do
      expect(EmployeeScope.new(branch_manager).relation).to include(branch_employee)
      expect(EmployeeScope.new(branch_manager).relation).not_to include(floating_employee)
    end

    it "sees none of the floating employee's attendance records or punch logs" do
      expect(visible_attendance_users(branch_manager)).to include(branch_employee.id)
      expect(visible_attendance_users(branch_manager)).not_to include(floating_employee.id)
      expect(visible_punch_log_employees(branch_manager)).not_to include(floating_employee.id)
    end
  end

  it "does not show the floating assignment to a branch manager with shift access" do
    manager = user_with(create(:permission_role, business: business, permissions: %w[view_shifts assign_shifts]))
    branch_a.update!(branch_manager: manager)

    visible = Pundit.policy_scope!(manager, ShiftAssignment)
    expect(visible.pluck(:user_id)).to include(branch_employee.id)
    expect(visible.pluck(:user_id)).not_to include(floating_employee.id)
  end

  it "lets a business-wide viewer see the floating employee's attendance and punches" do
    expect(visible_attendance_users(business_viewer)).to include(floating_employee.id, branch_employee.id)
    expect(visible_punch_log_employees(business_viewer)).to include(floating_employee.id)
  end

  it "lets the floating employee see their own attendance" do
    expect(visible_attendance_users(floating_employee)).to eq([ floating_employee.id ])
  end

  describe "a floating area manager" do
    let(:area_manager) do
      user_with(viewer_role).tap do |u|
        create(:shift_assignment, :floating, user: u, shift: shift)
        [ branch_a, branch_b, branch_c ].each { |b| b.update!(area_manager: u) }
      end
    end

    it "keeps access to the employees of the branches they area-manage" do
      c_employee = create(:user, business: business)
      create(:shift_assignment, user: c_employee, shift: shift, branch: branch_c)

      expect(EmployeeScope.new(area_manager).relation).to include(branch_employee, c_employee)
      expect(EmployeeScope.new(area_manager).for_scope("area")).to include(branch_employee, c_employee)
      expect(BranchScope.new(area_manager).for_scope("area")).to match_array([ branch_a.id, branch_b.id, branch_c.id ])
    end

    it "is not visible to the branch managers of those branches" do
      expect(EmployeeScope.new(branch_manager).relation).not_to include(area_manager)
    end
  end
end
