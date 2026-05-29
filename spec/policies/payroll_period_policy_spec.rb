require "rails_helper"

RSpec.describe PayrollPeriodPolicy, type: :model do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  let(:accountant)  { create(:user, :accountant,  business: business) }
  let(:manager)     { create(:user, :branch_manager, business: business) }
  let(:area_mgr)    { create(:user, :area_manager, business: business) }
  let(:employee)    { create(:user, business: business) }

  before { create(:user_branch, user: manager, branch: branch) }

  # All periods are company-wide — no branch scoping on PayrollPeriod.
  let(:period) { create(:payroll_period, business: business) }

  subject { described_class }

  describe "index?" do
    it "permits super_admin"    do expect(subject).to permit(super_admin, period) end
    it "permits accountant"     do expect(subject).to permit(accountant,  period) end
    it "permits area_manager"   do expect(subject).to permit(area_mgr,    period) end
    it "permits branch_manager" do expect(subject).to permit(manager,     period) end
    it "permits employee"       do expect(subject).to permit(employee,     period) end
  end

  describe "show?" do
    it "permits super_admin"    do expect(subject.new(super_admin, period).show?).to be true  end
    it "permits accountant"     do expect(subject.new(accountant,  period).show?).to be true  end
    it "permits area_manager"   do expect(subject.new(area_mgr,    period).show?).to be true  end
    it "permits branch_manager" do expect(subject.new(manager,     period).show?).to be true  end

    it "denies employee for a draft period with no entry" do
      expect(subject.new(employee, period).show?).to be false
    end

    it "permits employee when finalized and they have an entry" do
      finalized = create(:payroll_period, :finalized, business: business)
      create(:payroll_entry, payroll_period: finalized, user: employee)
      expect(subject.new(employee, finalized).show?).to be true
    end
  end

  describe "create?" do
    it "permits super_admin"   do expect(subject.new(super_admin, period).create?).to be true  end
    it "permits accountant"    do expect(subject.new(accountant,  period).create?).to be true  end
    it "denies area_manager"   do expect(subject.new(area_mgr,    period).create?).to be false end
    it "denies branch_manager" do expect(subject.new(manager,     period).create?).to be false end
    it "denies employee"       do expect(subject.new(employee,    period).create?).to be false end
  end

  describe "submit_for_review?" do
    it "permits super_admin"   do expect(subject.new(super_admin, period).submit_for_review?).to be true  end
    it "permits accountant"    do expect(subject.new(accountant,  period).submit_for_review?).to be true  end
    it "denies area_manager"   do expect(subject.new(area_mgr,    period).submit_for_review?).to be false end
    it "denies branch_manager" do expect(subject.new(manager,     period).submit_for_review?).to be false end
    it "denies employee"       do expect(subject.new(employee,    period).submit_for_review?).to be false end
  end

  describe "complete_branch_review?" do
    it "permits branch_manager in same business" do
      expect(subject.new(manager, period).complete_branch_review?).to be true
    end

    it "permits area_manager with view_payroll" do
      expect(subject.new(area_mgr, period).complete_branch_review?).to be true
    end

    it "permits accountant with view_payroll" do
      expect(subject.new(accountant, period).complete_branch_review?).to be true
    end

    it "denies branch_manager from a different business" do
      other_manager = create(:user, :branch_manager)
      expect(subject.new(other_manager, period).complete_branch_review?).to be false
    end
  end

  describe "regenerate?" do
    it "permits super_admin"   do expect(subject.new(super_admin, period).regenerate?).to be true  end
    it "permits accountant"    do expect(subject.new(accountant,  period).regenerate?).to be true  end
    it "denies area_manager"   do expect(subject.new(area_mgr,    period).regenerate?).to be false end
    it "denies branch_manager" do expect(subject.new(manager,     period).regenerate?).to be false end
    it "denies employee"       do expect(subject.new(employee,    period).regenerate?).to be false end
  end

  describe "finalize?" do
    it "permits super_admin"   do expect(subject.new(super_admin, period).finalize?).to be true  end
    it "denies accountant"     do expect(subject.new(accountant,  period).finalize?).to be false end
    it "denies branch_manager" do expect(subject.new(manager,     period).finalize?).to be false end
    it "denies employee"       do expect(subject.new(employee,    period).finalize?).to be false end
  end

  describe "mark_paid?" do
    it "permits super_admin"   do expect(subject.new(super_admin, period).mark_paid?).to be true  end
    it "permits accountant with manage_payroll" do expect(subject.new(accountant, period).mark_paid?).to be true end
    it "denies branch_manager" do expect(subject.new(manager,     period).mark_paid?).to be false end
  end

  describe "Scope" do
    # Use fixed months to avoid uniqueness conflicts with `period` (current month).
    let!(:business_period) { create(:payroll_period, business: business,
                                    period_year: 2025, period_month: 1) }
    let!(:other_period)    { create(:payroll_period) }

    it "super_admin sees all periods for the business" do
      scope = described_class::Scope.new(super_admin, PayrollPeriod).resolve
      expect(scope).to     include(business_period)
      expect(scope).not_to include(other_period)
    end

    it "accountant sees all periods for the business" do
      scope = described_class::Scope.new(accountant, PayrollPeriod).resolve
      expect(scope).to     include(business_period)
      expect(scope).not_to include(other_period)
    end

    it "area_manager sees all periods for the business" do
      scope = described_class::Scope.new(area_mgr, PayrollPeriod).resolve
      expect(scope).to     include(business_period)
      expect(scope).not_to include(other_period)
    end

    it "branch_manager sees all periods for the business" do
      scope = described_class::Scope.new(manager, PayrollPeriod).resolve
      expect(scope).to     include(business_period)
      expect(scope).not_to include(other_period)
    end

    it "employee sees only finalized/paid periods where they have an entry" do
      finalized = create(:payroll_period, :finalized, business: business,
                         period_year: 2025, period_month: 2)
      create(:payroll_entry, payroll_period: finalized, user: employee)

      draft_with_entry = create(:payroll_period, business: business,
                                period_year: 2025, period_month: 3)
      create(:payroll_entry, payroll_period: draft_with_entry, user: employee)

      scope = described_class::Scope.new(employee, PayrollPeriod).resolve
      expect(scope).to     include(finalized)
      expect(scope).not_to include(draft_with_entry)
      expect(scope).not_to include(other_period)
    end

    it "employee sees empty scope when no finalized periods exist with an entry" do
      scope = described_class::Scope.new(employee, PayrollPeriod).resolve
      expect(scope).to be_empty
    end
  end
end
