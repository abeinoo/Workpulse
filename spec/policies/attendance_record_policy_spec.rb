require "rails_helper"

RSpec.describe AttendanceRecordPolicy, type: :model do
  let(:business)      { create(:business) }
  let(:branch)        { create(:branch, business: business) }
  let(:super_admin)   { create(:user, :super_admin,   business: business) }
  let(:area_manager)  { create(:user, :area_manager,  business: business) }
  let(:manager)       { create(:user, :branch_manager, business: business) }
  let(:employee)      { create(:user, business: business, manager: manager) }
  let(:record)        { create(:attendance_record, branch: branch, user: employee) }

  before do
    create(:user_branch, user: manager,  branch: branch)
    create(:user_branch, user: employee, branch: branch)
    branch.update!(area_manager: area_manager)
  end

  subject { described_class }

  describe "index?" do
    it "permits super_admin"   do expect(subject).to permit(super_admin,  AttendanceRecord) end
    it "permits area_manager"  do expect(subject).to permit(area_manager, AttendanceRecord) end
    it "permits branch_manager" do expect(subject).to permit(manager,     AttendanceRecord) end
    it "permits employee"      do expect(subject).to permit(employee,     AttendanceRecord) end
  end

  describe "show?" do
    it "permits super_admin" do
      expect(subject).to permit(super_admin, record)
    end

    it "permits area_manager whose area includes this record's branch" do
      expect(subject).to permit(area_manager, record)
    end

    it "denies area_manager whose area does not include this record's branch" do
      other_area_manager = create(:user, :area_manager, business: business)
      expect(subject).not_to permit(other_area_manager, record)
    end

    it "permits branch_manager whose branch includes this record" do
      expect(subject).to permit(manager, record)
    end

    it "permits the employee who owns the record" do
      expect(subject).to permit(employee, record)
    end

    it "denies a different employee" do
      other = create(:user, business: business)
      expect(subject).not_to permit(other, record)
    end
  end

  describe "update? (edit gate — manager-based)" do
    context "super_admin" do
      it "can edit any employee record" do
        expect(subject).to permit(super_admin, record)
      end

      it "can edit a branch_manager record" do
        mgr_record = create(:attendance_record, user: manager, branch: branch)
        expect(subject).to permit(super_admin, mgr_record)
      end
    end

    context "area_manager" do
      it "cannot edit attendance records (view-only)" do
        expect(subject).not_to permit(area_manager, record)
      end
    end

    context "branch_manager" do
      it "can edit a record for their directly managed employee" do
        expect(subject).to permit(manager, record)
      end

      it "cannot edit their own attendance record" do
        own_record = create(:attendance_record, user: manager, branch: branch)
        expect(subject).not_to permit(manager, own_record)
      end

      it "cannot edit a super_admin record" do
        admin_record = create(:attendance_record, user: super_admin, branch: branch)
        expect(subject).not_to permit(manager, admin_record)
      end

      it "cannot edit an employee who belongs to a different manager" do
        other_manager = create(:user, :branch_manager, business: business)
        other_emp     = create(:user, business: business, manager: other_manager)
        create(:user_branch, user: other_emp, branch: branch)
        other_record  = create(:attendance_record, user: other_emp, branch: branch)
        expect(subject).not_to permit(manager, other_record)
      end

      it "cannot edit a record in a different branch" do
        other_branch = create(:branch, business: business)
        other_record = create(:attendance_record, branch: other_branch, user: employee)
        expect(subject).not_to permit(manager, other_record)
      end
    end

    context "employee" do
      it "cannot edit any attendance record" do
        expect(subject).not_to permit(employee, record)
      end

      it "cannot edit their own record" do
        own_record = create(:attendance_record, user: employee, branch: branch)
        expect(subject).not_to permit(employee, own_record)
      end
    end
  end

  describe "create?" do
    it "denies everyone" do
      [ super_admin, area_manager, manager, employee ].each do |user|
        expect(subject).not_to permit(user, AttendanceRecord.new)
      end
    end
  end

  describe "Scope" do
    let!(:emp_record)   { create(:attendance_record, branch: branch, user: employee) }
    let!(:mgr_record)   { create(:attendance_record, branch: branch, user: manager) }
    let!(:other_record) { create(:attendance_record) }

    describe "super_admin scope" do
      it "returns all records for the business" do
        scope = described_class::Scope.new(super_admin, AttendanceRecord).resolve
        expect(scope).to include(emp_record, mgr_record)
        expect(scope).not_to include(other_record)
      end
    end

    describe "area_manager scope" do
      it "includes records for employees in their area branches" do
        scope = described_class::Scope.new(area_manager, AttendanceRecord).resolve
        expect(scope).to include(emp_record, mgr_record)
        expect(scope).not_to include(other_record)
      end

      it "excludes records from branches not in their area" do
        other_branch = create(:branch, business: business)
        other_emp    = create(:user, business: business)
        outside_record = create(:attendance_record, branch: other_branch, user: other_emp)
        scope = described_class::Scope.new(area_manager, AttendanceRecord).resolve
        expect(scope).not_to include(outside_record)
      end

      it "includes the area manager's own records" do
        am_record = create(:attendance_record, branch: branch, user: area_manager)
        scope = described_class::Scope.new(area_manager, AttendanceRecord).resolve
        expect(scope).to include(am_record)
      end
    end

    describe "branch_manager scope" do
      it "includes records for employees in their branch" do
        scope = described_class::Scope.new(manager, AttendanceRecord).resolve
        expect(scope).to include(emp_record)
        expect(scope).not_to include(other_record)
      end

      it "includes their own records" do
        scope = described_class::Scope.new(manager, AttendanceRecord).resolve
        expect(scope).to include(mgr_record)
      end
    end

    describe "employee scope" do
      it "returns only own records" do
        scope = described_class::Scope.new(employee, AttendanceRecord).resolve
        expect(scope).to include(emp_record)
        expect(scope).not_to include(mgr_record, other_record)
      end
    end
  end
end
