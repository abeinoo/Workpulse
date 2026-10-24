require "rails_helper"

RSpec.describe PayrollAdjustmentPolicy, type: :model do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  let(:accountant)  { create(:user, :accountant,  business: business) }
  let(:manager)     { create(:user, :branch_manager, business: business) }
  let(:employee)    { create(:user, business: business) }

  before do
    branch.update_column(:branch_manager_id, manager.id)
  end

  let(:period)     { create(:payroll_period, business: business, branch: branch) }
  let(:adjustment) { create(:payroll_adjustment, :cash_incentive, payroll_period: period, user: employee, created_by: manager) }

  let(:area_manager) { create(:user, :area_manager, business: business) }
  let(:blank_record) { PayrollAdjustment.new(business: business) }

  subject { described_class }

  describe "index?" do
    it "permits an employee (Scope limits them to their own approved adjustments)" do
      expect(subject.new(employee, blank_record).index?).to be true
    end

    it "permits a branch_manager" do
      expect(subject.new(manager, blank_record).index?).to be true
    end

    it "permits class-level authorize (e.g. the API collection)" do
      expect(subject.new(employee, PayrollAdjustment).index?).to be true
    end

    it "denies a user from another business" do
      foreign = create(:user, business: create(:business))
      expect(subject.new(foreign, blank_record).index?).to be false
    end
  end

  describe "new?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, blank_record).new?).to be true
    end

    it "permits branch_manager" do
      expect(subject.new(manager, blank_record).new?).to be true
    end

    it "permits area_manager" do
      expect(subject.new(area_manager, blank_record).new?).to be true
    end

    it "permits accountant with manage_adjustments" do
      expect(subject.new(accountant, blank_record).new?).to be true
    end

    it "denies employee" do
      expect(subject.new(employee, blank_record).new?).to be false
    end
  end

  describe "create?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, adjustment).create?).to be true
    end

    it "permits accountant" do
      expect(subject.new(accountant, adjustment).create?).to be true
    end

    it "permits branch_manager for their employee" do
      expect(subject.new(manager, adjustment).create?).to be true
    end

    it "denies employee" do
      expect(subject.new(employee, adjustment).create?).to be false
    end
  end

  # adjustment is created_by: manager (see top-level let).
  describe "approve? / reject?" do
    it "permits super_admin (not the creator)" do
      expect(subject.new(super_admin, adjustment).approve?).to be true
      expect(subject.new(super_admin, adjustment).reject?).to be true
    end

    it "DENIES the creator from approving/rejecting their own adjustment" do
      # Creator != Approver. Even though the branch_manager holds approve_adjustments,
      # they may not approve the adjustment they themselves created.
      expect(subject.new(manager, adjustment).approve?).to be false
      expect(subject.new(manager, adjustment).reject?).to be false
    end

    it "permits a different approver (area_manager) with approve_adjustments" do
      expect(subject.new(area_manager, adjustment).approve?).to be true
      expect(subject.new(area_manager, adjustment).reject?).to be true
    end

    it "permits accountant with approve_adjustments (not the creator)" do
      expect(subject.new(accountant, adjustment).approve?).to be true
    end

    it "denies a user without approve_adjustments" do
      expect(subject.new(employee, adjustment).approve?).to be false
    end

    %w[approved rejected].each do |status|
      it "denies reviewing an adjustment that is already #{status}" do
        adjustment.update_column(:review_status, status)
        expect(subject.new(super_admin, adjustment).approve?).to be false
        expect(subject.new(super_admin, adjustment).reject?).to be false
      end
    end

    %i[finalized paid].each do |status|
      it "denies reviewing a pending adjustment in a #{status} period" do
        adjustment.payroll_period.update_column(:status, status.to_s)
        expect(subject.new(super_admin, adjustment).approve?).to be false
        expect(subject.new(super_admin, adjustment).reject?).to be false
      end

      it "denies reviewing a standalone adjustment whose month's period is #{status}" do
        standalone = create(:payroll_adjustment, :cash_incentive, payroll_period: nil, business: business,
                            period_month: period.period_month, period_year: period.period_year,
                            user: employee, created_by: manager)
        period.update_column(:status, status.to_s)
        expect(subject.new(super_admin, standalone).approve?).to be false
        expect(subject.new(super_admin, standalone).reject?).to be false
      end
    end
  end

  # Adjustment Analytics & Reports are visible only to Business-scope users.
  describe "analytics? / reports?" do
    it "permits the owner (super_admin)" do
      expect(subject.new(super_admin, blank_record).analytics?).to be true
      expect(subject.new(super_admin, blank_record).reports?).to be true
    end

    it "permits a business-scope admin (accountant, view_payroll business-wide)" do
      expect(subject.new(accountant, blank_record).analytics?).to be true
      expect(subject.new(accountant, blank_record).reports?).to be true
    end

    it "denies a branch-scope manager" do
      expect(subject.new(manager, blank_record).analytics?).to be false
      expect(subject.new(manager, blank_record).reports?).to be false
    end

    it "denies an area-scope manager" do
      expect(subject.new(area_manager, blank_record).analytics?).to be false
      expect(subject.new(area_manager, blank_record).reports?).to be false
    end

    it "denies a plain employee" do
      expect(subject.new(employee, blank_record).analytics?).to be false
      expect(subject.new(employee, blank_record).reports?).to be false
    end

    it "denies a cross-business user even if they are a business-scope owner elsewhere" do
      foreign_owner = create(:user, :super_admin, business: create(:business))
      expect(subject.new(foreign_owner, blank_record).analytics?).to be false
    end
  end

  describe "bulk_approve? / bulk_reject?" do
    it "permits a reviewer with approve_adjustments (accountant)" do
      expect(subject.new(accountant, blank_record).bulk_approve?).to be true
      expect(subject.new(accountant, blank_record).bulk_reject?).to be true
    end

    it "permits a branch_manager (holds approve_adjustments)" do
      expect(subject.new(manager, blank_record).bulk_approve?).to be true
      expect(subject.new(manager, blank_record).bulk_reject?).to be true
    end

    it "permits an area_manager" do
      expect(subject.new(area_manager, blank_record).bulk_approve?).to be true
    end

    it "denies a plain employee" do
      expect(subject.new(employee, blank_record).bulk_approve?).to be false
      expect(subject.new(employee, blank_record).bulk_reject?).to be false
    end

    it "denies a user from another business" do
      foreign = create(:user, :accountant, business: create(:business))
      expect(subject.new(foreign, blank_record).bulk_approve?).to be false
    end
  end

  describe "show?" do
    it "permits the creator to view their own adjustment" do
      expect(subject.new(manager, adjustment).show?).to be true
    end

    it "permits the subject employee to view an APPROVED adjustment about themselves" do
      approved = create(:payroll_adjustment, :cash_incentive, :approved,
                        payroll_period: period, user: employee, created_by: manager)
      expect(subject.new(employee, approved).show?).to be true
    end

    it "DENIES the subject employee from viewing a pending adjustment about themselves" do
      # adjustment is pending_review by factory default — not yet visible to the subject.
      expect(subject.new(employee, adjustment).show?).to be false
    end

    it "permits a reviewer with view_payroll/manage_adjustments" do
      expect(subject.new(accountant, adjustment).show?).to be true
      expect(subject.new(super_admin, adjustment).show?).to be true
    end

    it "denies an unrelated employee with no payroll permissions" do
      outsider = create(:user, business: business)
      expect(subject.new(outsider, adjustment).show?).to be false
    end
  end

  describe "destroy?" do
    context "draft period, adjustment created by manager" do
      it "permits super_admin" do
        expect(subject.new(super_admin, adjustment).destroy?).to be true
      end

      it "permits the creator (branch_manager)" do
        expect(subject.new(manager, adjustment).destroy?).to be true
      end

      it "permits accountant with manage_adjustments regardless of creator" do
        expect(subject.new(accountant, adjustment).destroy?).to be true
      end

      it "permits accountant who did create it" do
        adj = create(:payroll_adjustment, :cash_incentive, payroll_period: period, user: employee, created_by: accountant)
        expect(subject.new(accountant, adj).destroy?).to be true
      end
    end

    context "when adjustment is already approved (not pending)" do
      let(:adjustment) do
        create(:payroll_adjustment, :cash_incentive, payroll_period: period, user: employee,
               created_by: manager, review_status: :approved)
      end

      it "denies super_admin" do
        expect(subject.new(super_admin, adjustment).destroy?).to be false
      end

      it "denies accountant" do
        expect(subject.new(accountant, adjustment).destroy?).to be false
      end

      it "denies branch_manager" do
        expect(subject.new(manager, adjustment).destroy?).to be false
      end
    end
  end

  describe "Scope" do
    let!(:my_adjustment) { adjustment }
    let(:other_business)    { create(:business) }
    let(:other_period)      { create(:payroll_period, business: other_business) }
    let(:other_employee)    { create(:user, business: other_business) }
    let!(:other_adjustment) do
      create(:payroll_adjustment, :cash_incentive,
        payroll_period: other_period,
        user:           other_employee,
        created_by:     create(:user, :super_admin, business: other_business)
      )
    end

    it "super_admin sees all adjustments in their business" do
      scope = described_class::Scope.new(super_admin, PayrollAdjustment).resolve
      expect(scope).to include(my_adjustment)
      expect(scope).not_to include(other_adjustment)
    end

    it "accountant sees all adjustments in their business" do
      scope = described_class::Scope.new(accountant, PayrollAdjustment).resolve
      expect(scope).to include(my_adjustment)
      expect(scope).not_to include(other_adjustment)
    end

    it "employee sees only their own APPROVED adjustments" do
      my_approved = create(:payroll_adjustment, :cash_incentive, :approved,
                           payroll_period: period, user: employee, created_by: manager)

      scope = described_class::Scope.new(employee, PayrollAdjustment).resolve
      expect(scope).to include(my_approved)
      expect(scope).not_to include(my_adjustment)    # their own, but still pending → hidden
      expect(scope).not_to include(other_adjustment) # other business
    end

    it "employee does NOT see a pending or rejected adjustment about themselves" do
      pending  = my_adjustment # pending_review by factory default
      rejected = create(:payroll_adjustment, :cash_incentive, payroll_period: period,
                        user: employee, created_by: manager, review_status: :rejected)

      scope = described_class::Scope.new(employee, PayrollAdjustment).resolve
      expect(scope).not_to include(pending)
      expect(scope).not_to include(rejected)
    end

    it "employee does NOT see a co-worker's adjustment in the same business" do
      coworker     = create(:user, business: business)
      coworker_adj = create(:payroll_adjustment, :cash_incentive, :approved, payroll_period: period,
                            user: coworker, created_by: manager)

      scope = described_class::Scope.new(employee, PayrollAdjustment).resolve
      expect(scope).not_to include(coworker_adj)     # belongs to another employee
    end

    it "a creator always sees adjustments they created, even for an out-of-scope employee" do
      far_employee = create(:user, business: business)  # not in manager's branch scope
      far_period   = create(:payroll_period, business: business, period_year: 2025, period_month: 7)
      created_by_manager = create(:payroll_adjustment, :cash_incentive,
        payroll_period: far_period, user: far_employee, created_by: manager)

      scope = described_class::Scope.new(manager, PayrollAdjustment).resolve
      expect(scope).to include(created_by_manager)
    end

    describe "branch_manager scope isolation" do
      let(:other_branch)    { create(:branch, business: business) }
      let(:other_mgr)       { create(:user, :branch_manager, business: business) }
      let(:other_emp)       { create(:user, business: business) }
      let(:other_adj_period) { create(:payroll_period, business: business, branch: other_branch,
                                      period_year: 2025, period_month: 3) }
      let!(:other_branch_adj) do
        other_branch.update_column(:branch_manager_id, other_mgr.id)
        create(:payroll_adjustment, :cash_incentive,
               payroll_period: other_adj_period,
               user:           other_emp,
               created_by:     other_mgr)
      end

      it "includes adjustments for employees in their own branch" do
        scope = described_class::Scope.new(manager, PayrollAdjustment).resolve
        expect(scope).to include(my_adjustment)
      end

      it "excludes adjustments for employees in a different branch" do
        scope = described_class::Scope.new(manager, PayrollAdjustment).resolve
        expect(scope).not_to include(other_branch_adj)
      end

      it "excludes adjustments from other businesses" do
        scope = described_class::Scope.new(manager, PayrollAdjustment).resolve
        expect(scope).not_to include(other_adjustment)
      end
    end
  end

  # ── Payroll locking: finalized / paid periods ─────────────────────────────
  describe "locking (finalized period)" do
    let(:finalized_period) do
      create(:payroll_period, :finalized, business: business)
    end
    # Created approved: a pending adjustment can no longer be created in a
    # finalized period; each example sets the status it needs.
    let(:locked_adj) do
      create(:payroll_adjustment, :cash_incentive,
             payroll_period: finalized_period,
             user:           employee,
             created_by:     super_admin,
             review_status:  :approved)
    end

    it "blocks create? on a finalized period even for super_admin" do
      locked_adj.review_status = "pending_review"
      expect(described_class.new(super_admin, locked_adj).create?).to be false
    end

    it "blocks destroy? on a finalized period" do
      locked_adj.update_column(:review_status, "pending_review")
      expect(described_class.new(super_admin, locked_adj).destroy?).to be false
    end

    it "still allows create? on a draft period" do
      draft_adj = PayrollAdjustment.new(business: business, payroll_period: period, user: employee)
      expect(described_class.new(super_admin, draft_adj).create?).to be true
    end
  end

  describe "locking (paid period)" do
    let(:paid_period) { create(:payroll_period, :paid, business: business) }
    let(:paid_adj) do
      create(:payroll_adjustment, :cash_incentive,
             payroll_period: paid_period,
             user:           employee,
             created_by:     super_admin,
             review_status:  :pending_review)
    end

    it "blocks create? on a paid period" do
      new_adj = PayrollAdjustment.new(business: business, payroll_period: paid_period, user: employee)
      expect(described_class.new(super_admin, new_adj).create?).to be false
    end
  end
end
