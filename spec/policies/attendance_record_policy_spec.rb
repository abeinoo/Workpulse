require "rails_helper"

RSpec.describe AttendanceRecordPolicy, type: :model do
  let(:business)      { create(:business) }
  let(:branch)        { create(:branch, business: business) }
  let(:super_admin)   { create(:user, :super_admin,   business: business) }
  let(:area_manager)  { create(:user, :area_manager,  business: business) }
  let(:manager)       { create(:user, :branch_manager, business: business) }
  let(:employee)      { create(:user, business: business) }
  let(:record)        { create(:attendance_record, branch: branch, user: employee) }

  before do
    branch.update!(area_manager: area_manager, branch_manager: manager)
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

    it "permits any area_manager with view_attendance — scope restricts which records load" do
      other_area_manager = create(:user, :area_manager, business: business)
      expect(subject).to permit(other_area_manager, record)
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

    context "area_manager (has manage_attendance permission)" do
      it "can edit attendance records" do
        expect(subject).to permit(area_manager, record)
      end
    end

    context "branch_manager (has manage_attendance permission)" do
      it "can edit a record for their directly managed employee" do
        expect(subject).to permit(manager, record)
      end

      it "can edit their own attendance record" do
        own_record = create(:attendance_record, user: manager, branch: branch)
        expect(subject).to permit(manager, own_record)
      end

      it "can edit any record via manage_attendance — scope limits which records load" do
        admin_record = create(:attendance_record, user: super_admin, branch: branch)
        expect(subject).to permit(manager, admin_record)
      end

      it "can edit any same-business record at policy level — scope enforces branch isolation" do
        other_emp     = create(:user, business: business)
        other_record  = create(:attendance_record, user: other_emp, branch: branch)
        expect(subject).to permit(manager, other_record)
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

  describe "destroy?" do
    it "denies a branch_manager with only manage_attendance (not delete_attendance)" do
      expect(subject).not_to permit(manager, record)
    end

    it "denies an employee" do
      expect(subject).not_to permit(employee, record)
    end

    it "permits a user granted delete_attendance" do
      role = create(:permission_role, business: business,
                     permissions: %w[view_attendance manage_attendance delete_attendance])
      deleter = create(:user, business: business, permission_role: role)
      expect(subject).to permit(deleter, record)
    end
  end

  describe "create?" do
    it "permits users with manage_attendance (manual entry)" do
      [ super_admin, area_manager, manager ].each do |user|
        expect(subject).to permit(user, AttendanceRecord.new)
      end
    end

    it "denies users without manage_attendance" do
      expect(subject).not_to permit(employee, AttendanceRecord.new)
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

  # ──────────────────────────────────────────────────────────────
  # Explicitly configured view_attendance data scopes (regression).
  # Previously these dropped the current user and, for "branch_only",
  # returned nobody when the user wasn't the formal branch manager.
  # ──────────────────────────────────────────────────────────────
  describe "Scope — explicit configured data scopes" do
    def role_with_scope(scope_value)
      create(:permission_role, business: business,
             name: "View #{scope_value}",
             permissions: %w[view_attendance],
             permission_scopes: { "view_attendance" => scope_value })
    end

    let!(:other_record) { create(:attendance_record) } # different business — never visible

    describe "branch_only" do
      # The branch manager of `branch`. Branch membership for colleagues is
      # shift-driven (the attendance_record factory creates the active assignment).
      let(:viewer)    { create(:user, business: business, permission_role: role_with_scope("branch_only")) }
      let(:colleague) { create(:user, business: business) }

      let!(:viewer_record)    { create(:attendance_record, branch: branch, user: viewer) }
      let!(:colleague_record) { create(:attendance_record, branch: branch, user: colleague) }

      before { branch.update_column(:branch_manager_id, viewer.id) }

      it "shows all branch colleagues including the current user" do
        scope = described_class::Scope.new(viewer, AttendanceRecord).resolve
        expect(scope).to include(viewer_record, colleague_record)
        expect(scope).not_to include(other_record)
      end

      it "excludes employees from other branches" do
        other_branch = create(:branch, business: business)
        outsider     = create(:user, business: business)
        outsider_rec = create(:attendance_record, branch: other_branch, user: outsider)

        scope = described_class::Scope.new(viewer, AttendanceRecord).resolve
        expect(scope).not_to include(outsider_rec)
      end
    end

    # branch scope: the viewer (branch manager) sees colleagues assigned to their
    # branch and their own records, not people in other branches.
    describe "branch" do
      let(:viewer)    { create(:user, business: business, permission_role: role_with_scope("branch")) }
      let(:colleague) { create(:user, business: business) }
      let(:stranger)  { create(:user, business: business) }
      let(:other_branch) { create(:branch, business: business) }

      let!(:viewer_record)    { create(:attendance_record, branch: branch, user: viewer) }
      let!(:colleague_record) { create(:attendance_record, branch: branch, user: colleague) }
      let!(:stranger_record)  { create(:attendance_record, branch: other_branch, user: stranger) }

      before { branch.update_column(:branch_manager_id, viewer.id) }

      it "shows branch colleagues and the viewer's own records, not other branches" do
        scope = described_class::Scope.new(viewer, AttendanceRecord).resolve
        expect(scope).to include(viewer_record, colleague_record)
        expect(scope).not_to include(stranger_record, other_record)
      end
    end

    describe "business_wide" do
      let(:viewer)  { create(:user, business: business, permission_role: role_with_scope("business_wide")) }
      let(:someone) { create(:user, business: business) }

      let!(:viewer_record)  { create(:attendance_record, branch: branch, user: viewer) }
      let!(:someone_record) { create(:attendance_record, branch: branch, user: someone) }

      it "shows every record in the business including the user's own" do
        scope = described_class::Scope.new(viewer, AttendanceRecord).resolve
        expect(scope).to include(viewer_record, someone_record)
        expect(scope).not_to include(other_record)
      end
    end

    describe "self_only" do
      let(:viewer)  { create(:user, business: business, permission_role: role_with_scope("self_only")) }
      let(:someone) { create(:user, business: business) }

      let!(:viewer_record)  { create(:attendance_record, branch: branch, user: viewer) }
      let!(:someone_record) { create(:attendance_record, branch: branch, user: someone) }

      it "shows only the user's own records" do
        scope = described_class::Scope.new(viewer, AttendanceRecord).resolve
        expect(scope).to include(viewer_record)
        expect(scope).not_to include(someone_record, other_record)
      end
    end
  end
end
