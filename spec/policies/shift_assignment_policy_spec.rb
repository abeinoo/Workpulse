require "rails_helper"

RSpec.describe ShiftAssignmentPolicy, type: :model do
  let(:business)     { create(:business) }
  let(:branch)       { create(:branch, business: business) }
  let(:other_branch) { create(:branch, business: business) }

  let(:super_admin)  { create(:user, :super_admin,    business: business) }
  let(:area_manager) { create(:user, :area_manager,   business: business) }
  let(:manager)      { create(:user, :branch_manager, business: business) }
  let(:employee)     { create(:user, business: business) }

  let(:assignment)       { create(:shift_assignment, branch: branch) }
  let(:other_assignment) { create(:shift_assignment, branch: other_branch) }
  let(:own_assignment)   { create(:shift_assignment, user: employee, branch: branch) }

  before do
    branch.update_column(:area_manager_id,  area_manager.id)
    branch.update_column(:branch_manager_id, manager.id)
    create(:user_branch, user: area_manager, branch: branch)
    create(:user_branch, user: manager,      branch: branch)
    create(:user_branch, user: employee,     branch: branch)
  end

  subject { described_class }

  describe "index?" do
    it "permits super_admin"    do expect(subject).to     permit(super_admin,  assignment) end
    it "permits area_manager"   do expect(subject).to     permit(area_manager, assignment) end
    it "permits branch_manager" do expect(subject).to     permit(manager,      assignment) end
    it "permits employee"       do expect(subject).to     permit(employee,     assignment) end
  end

  describe "create?" do
    it "permits super_admin"    do expect(subject).to     permit(super_admin,  ShiftAssignment.new) end
    it "permits area_manager"   do expect(subject).to     permit(area_manager, ShiftAssignment.new) end
    it "permits branch_manager" do expect(subject).to     permit(manager,      ShiftAssignment.new) end
    it "denies employee"        do expect(subject).not_to permit(employee,     ShiftAssignment.new) end
  end

  describe "update?" do
    it "permits super_admin"    do expect(subject).to     permit(super_admin,  assignment) end
    it "permits area_manager"   do expect(subject).to     permit(area_manager, assignment) end
    it "permits branch_manager" do expect(subject).to     permit(manager,      assignment) end
    it "denies employee"        do expect(subject).not_to permit(employee,     assignment) end
  end

  describe "end_assignment?" do
    it "permits super_admin for any assignment" do
      expect(subject).to permit(super_admin, other_assignment)
    end

    it "permits area_manager for an assignment in their branch" do
      expect(subject).to permit(area_manager, assignment)
    end

    it "permits area_manager — scope handles branch isolation, not policy" do
      expect(subject).to permit(area_manager, other_assignment)
    end

    it "permits branch_manager for an assignment in their branch" do
      expect(subject).to permit(manager, assignment)
    end

    it "permits branch_manager — scope handles branch isolation, not policy" do
      expect(subject).to permit(manager, other_assignment)
    end

    it "denies employee" do
      expect(subject).not_to permit(employee, own_assignment)
    end
  end

  describe "destroy?" do
    context "when the assignment has no attendance records (deletable)" do
      # The factory-built assignment has no attendance records so deletable? = true
      it "permits super_admin"   do expect(subject).to     permit(super_admin,  assignment) end
      it "permits area_manager with assign_shifts"   do expect(subject).to permit(area_manager, assignment) end
      it "permits branch_manager with assign_shifts" do expect(subject).to permit(manager,      assignment) end
      it "denies employee"       do expect(subject).not_to permit(employee,     assignment) end
    end

    context "when the assignment has attendance records (not deletable)" do
      before do
        AttendanceRecord.create!(
          user:                assignment.user,
          branch:              assignment.branch,
          shift_assignment:    assignment,
          work_date:           1.week.ago.to_date,
          date:                1.week.ago.to_date,
          check_in_at:         1.week.ago.change(hour: 9),
          check_in_source:     "biometric_device",
          late_minutes:        0,
          early_leave_minutes: 0,
          status:              "incomplete"
        )
      end

      it "denies super_admin because deletable? is false" do
        expect(subject).not_to permit(super_admin, assignment)
      end
    end
  end

  describe "bulk_end?" do
    it "permits super_admin"    do expect(subject).to     permit(super_admin,  ShiftAssignment.new) end
    it "permits area_manager"   do expect(subject).to     permit(area_manager, ShiftAssignment.new) end
    it "permits branch_manager" do expect(subject).to     permit(manager,      ShiftAssignment.new) end
    it "denies employee"        do expect(subject).not_to permit(employee,     ShiftAssignment.new) end
  end

  describe "bulk_delete?" do
    it "permits super_admin"   do expect(subject).to     permit(super_admin,  ShiftAssignment.new) end
    it "permits area_manager with assign_shifts"   do expect(subject).to permit(area_manager, ShiftAssignment.new) end
    it "permits branch_manager with assign_shifts" do expect(subject).to permit(manager,      ShiftAssignment.new) end
    it "denies employee"       do expect(subject).not_to permit(employee,     ShiftAssignment.new) end
  end

  describe "Scope" do
    let(:other_employee)           { create(:user, business: business) }
    let!(:branch_assignment)       { create(:shift_assignment, user: create(:user, business: business), branch: branch) }
    let!(:other_branch_assignment) { create(:shift_assignment, user: create(:user, business: business), branch: other_branch) }
    let!(:emp_assignment)          { create(:shift_assignment, user: employee, branch: branch) }

    def resolve_for(user)
      described_class::Scope.new(user, ShiftAssignment).resolve
    end

    it "super_admin sees all business assignments" do
      result = resolve_for(super_admin)
      expect(result).to include(branch_assignment, other_branch_assignment, emp_assignment)
    end

    it "area_manager sees only assignments in their branches" do
      result = resolve_for(area_manager)
      expect(result).to include(branch_assignment, emp_assignment)
      expect(result).not_to include(other_branch_assignment)
    end

    it "branch_manager sees only assignments in their branches" do
      result = resolve_for(manager)
      expect(result).to include(branch_assignment, emp_assignment)
      expect(result).not_to include(other_branch_assignment)
    end

    it "employee sees only their own assignments" do
      result = resolve_for(employee)
      expect(result).to include(emp_assignment)
      expect(result).not_to include(branch_assignment)
    end
  end
end
