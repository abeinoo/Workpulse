require "rails_helper"

RSpec.describe PayrollLineItemPolicy, type: :model do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  let(:accountant)  { create(:user, :accountant,  business: business) }
  let(:manager)     { create(:user, :branch_manager, business: business) }
  let(:employee)    { create(:user, business: business) }

  before do
    branch.update_column(:branch_manager_id, manager.id)
    create(:user_branch, user: manager,  branch: branch)
    create(:user_branch, user: employee, branch: branch)
  end

  let(:period)    { create(:payroll_period, business: business, branch: branch) }
  let(:entry)     { create(:payroll_entry,  payroll_period: period, user: employee) }
  let(:line_item) { create(:payroll_line_item, :late_penalty, payroll_entry: entry) }

  subject { described_class }

  describe "approve?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, line_item).approve?).to be true
    end

    it "permits accountant with approve_adjustments" do
      expect(subject.new(accountant, line_item).approve?).to be true
    end

    it "permits branch_manager with approve_adjustments" do
      expect(subject.new(manager, line_item).approve?).to be true
    end

    it "denies employee" do
      expect(subject.new(employee, line_item).approve?).to be false
    end
  end

  describe "reject?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, line_item).reject?).to be true
    end

    it "permits accountant with approve_adjustments" do
      expect(subject.new(accountant, line_item).reject?).to be true
    end

    it "permits branch_manager with approve_adjustments" do
      expect(subject.new(manager, line_item).reject?).to be true
    end

    it "denies employee" do
      expect(subject.new(employee, line_item).reject?).to be false
    end

    context "branch_manager from a different branch also has approve_adjustments" do
      let(:other_branch)  { create(:branch, business: business) }
      let(:other_manager) { create(:user, :branch_manager, business: business) }

      before { create(:user_branch, user: other_manager, branch: other_branch) }

      it "permits manager from another branch with approve_adjustments" do
        expect(subject.new(other_manager, line_item).reject?).to be true
      end
    end
  end

  describe "waive?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, line_item).waive?).to be true
    end

    it "permits accountant with approve_adjustments" do
      expect(subject.new(accountant, line_item).waive?).to be true
    end

    it "permits branch_manager with approve_adjustments" do
      expect(subject.new(manager, line_item).waive?).to be true
    end

    it "denies employee" do
      expect(subject.new(employee, line_item).waive?).to be false
    end

    context "branch_manager from another branch still has approve_adjustments permission" do
      let(:other_branch)  { create(:branch, business: business) }
      let(:other_manager) { create(:user, :branch_manager, business: business) }

      before { create(:user_branch, user: other_manager, branch: other_branch) }

      it "permits the manager — scope enforces employee boundary, not policy" do
        expect(subject.new(other_manager, line_item).waive?).to be true
      end
    end

    context "branch_manager from a different business" do
      let(:other_manager) { create(:user, :branch_manager) }

      it "denies the manager" do
        expect(subject.new(other_manager, line_item).waive?).to be false
      end
    end
  end

  describe "Scope" do
    let!(:line_item)       { create(:payroll_line_item, :late_penalty, payroll_entry: entry) }
    let!(:other_line_item) { create(:payroll_line_item, :late_penalty) }

    it "super_admin sees all items in business" do
      scope = described_class::Scope.new(super_admin, PayrollLineItem).resolve
      expect(scope).to include(line_item)
      expect(scope).not_to include(other_line_item)
    end

    it "accountant sees all items in business" do
      scope = described_class::Scope.new(accountant, PayrollLineItem).resolve
      expect(scope).to include(line_item)
      expect(scope).not_to include(other_line_item)
    end

    it "employee sees only their own line items" do
      scope = described_class::Scope.new(employee, PayrollLineItem).resolve
      expect(scope).to include(line_item)
      expect(scope).not_to include(other_line_item)
    end

    describe "branch_manager scope — EmployeeScope delegation" do
      it "includes line items for employees assigned to their branch via user_branches" do
        scope = described_class::Scope.new(manager, PayrollLineItem).resolve
        expect(scope).to include(line_item)
      end

      it "excludes line items for employees in a different branch" do
        other_branch = create(:branch, business: business)
        other_emp    = create(:user, business: business)
        create(:user_branch, user: other_emp, branch: other_branch)
        other_entry = create(:payroll_entry, payroll_period: period, user: other_emp)
        other_item  = create(:payroll_line_item, :late_penalty, payroll_entry: other_entry)

        scope = described_class::Scope.new(manager, PayrollLineItem).resolve
        expect(scope).not_to include(other_item)
      end

      it "includes line items for direct reports not in user_branches (EmployeeScope direct-report path)" do
        # Direct reports of a branch manager are visible via manager_id even without a user_branch row.
        direct_report       = create(:user, business: business, manager: manager)
        direct_report_entry = create(:payroll_entry, payroll_period: period, user: direct_report)
        direct_report_item  = create(:payroll_line_item, :late_penalty, payroll_entry: direct_report_entry)

        scope = described_class::Scope.new(manager, PayrollLineItem).resolve
        expect(scope).to include(direct_report_item)
      end

      it "excludes items from a completely different business" do
        scope = described_class::Scope.new(manager, PayrollLineItem).resolve
        expect(scope).not_to include(other_line_item)
      end
    end

    describe "view_payroll scope respects scope_for configuration" do
      it "business_wide scope (accountant default) sees all business items" do
        scope = described_class::Scope.new(accountant, PayrollLineItem).resolve
        expect(scope).to include(line_item)
        expect(scope).not_to include(other_line_item)
      end

      it "managed_employees_only scope limits to EmployeeScope hierarchy" do
        scoped_manager = create(:user, business: business)
        # Give the user view_payroll with managed_employees_only scope
        role = create(:permission_role, business: business,
                      permissions: %w[view_payroll],
                      permission_scopes: { "view_payroll" => "managed_employees_only" })
        scoped_manager.update_column(:permission_role_id, role.id)
        branch_a = create(:branch, business: business)
        branch_a.update_column(:branch_manager_id, scoped_manager.id)
        managed_emp   = create(:user, business: business)
        create(:user_branch, user: managed_emp, branch: branch_a)
        managed_entry = create(:payroll_entry, payroll_period: period, user: managed_emp)
        managed_item  = create(:payroll_line_item, :late_penalty, payroll_entry: managed_entry)

        scope = described_class::Scope.new(scoped_manager, PayrollLineItem).resolve
        expect(scope).to include(managed_item)
        # employee from branch (from outer `before`) is not in scoped_manager's branches
        expect(scope).not_to include(line_item)
      end
    end
  end

  # ── Payroll locking: finalized / paid periods ─────────────────────────────
  describe "locking" do
    let(:finalized_period) { create(:payroll_period, :finalized, business: business) }
    let(:finalized_entry) do
      create(:payroll_entry, payroll_period: finalized_period, user: create(:user, business: business))
    end
    let(:locked_item) do
      create(:payroll_line_item, :late_penalty, payroll_entry: finalized_entry)
    end

    it "blocks approve? on a finalized period" do
      expect(described_class.new(super_admin, locked_item).approve?).to be false
    end

    it "blocks reject? on a finalized period" do
      expect(described_class.new(super_admin, locked_item).reject?).to be false
    end

    it "blocks waive? on a finalized period" do
      expect(described_class.new(super_admin, locked_item).waive?).to be false
    end

    it "permits approve? on a draft period" do
      draft_entry = create(:payroll_entry, payroll_period: period, user: create(:user, business: business))
      draft_item  = create(:payroll_line_item, :late_penalty, payroll_entry: draft_entry)
      expect(described_class.new(super_admin, draft_item).approve?).to be true
    end
  end
end
