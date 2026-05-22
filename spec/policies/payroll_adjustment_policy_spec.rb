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
    create(:user_branch, user: manager,  branch: branch)
    create(:user_branch, user: employee, branch: branch)
  end

  let(:period)     { create(:payroll_period, business: business, branch: branch) }
  let(:adjustment) { create(:payroll_adjustment, :cash_incentive, payroll_period: period, user: employee, created_by: manager) }

  let(:area_manager) { create(:user, :area_manager, business: business) }
  let(:blank_record) { PayrollAdjustment.new(business: business) }

  subject { described_class }

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

    it "denies accountant" do
      expect(subject.new(accountant, blank_record).new?).to be false
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

  describe "approve? / reject?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, adjustment).approve?).to be true
      expect(subject.new(super_admin, adjustment).reject?).to be true
    end

    it "denies branch_manager" do
      expect(subject.new(manager, adjustment).approve?).to be false
      expect(subject.new(manager, adjustment).reject?).to be false
    end

    it "denies area_manager" do
      expect(subject.new(area_manager, adjustment).approve?).to be false
      expect(subject.new(area_manager, adjustment).reject?).to be false
    end

    it "denies accountant" do
      expect(subject.new(accountant, adjustment).approve?).to be false
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

      it "denies accountant who did not create it" do
        expect(subject.new(accountant, adjustment).destroy?).to be false
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

    it "employee sees only their own adjustments" do
      scope = described_class::Scope.new(employee, PayrollAdjustment).resolve
      expect(scope).to include(my_adjustment)
      expect(scope).not_to include(other_adjustment)
    end
  end
end
