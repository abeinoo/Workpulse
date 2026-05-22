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

    it "denies accountant" do
      expect(subject.new(accountant, line_item).approve?).to be false
    end

    it "denies branch_manager for their branch" do
      expect(subject.new(manager, line_item).approve?).to be false
    end

    it "denies employee" do
      expect(subject.new(employee, line_item).approve?).to be false
    end
  end

  describe "reject?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, line_item).reject?).to be true
    end

    it "denies accountant" do
      expect(subject.new(accountant, line_item).reject?).to be false
    end

    it "denies branch_manager for their branch" do
      expect(subject.new(manager, line_item).reject?).to be false
    end

    it "denies employee" do
      expect(subject.new(employee, line_item).reject?).to be false
    end

    context "branch_manager from a different branch" do
      let(:other_branch)  { create(:branch, business: business) }
      let(:other_manager) { create(:user, :branch_manager, business: business) }

      before { create(:user_branch, user: other_manager, branch: other_branch) }

      it "denies manager from another branch" do
        expect(subject.new(other_manager, line_item).reject?).to be false
      end
    end
  end

  describe "waive?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, line_item).waive?).to be true
    end

    it "denies accountant" do
      expect(subject.new(accountant, line_item).waive?).to be false
    end

    it "permits branch_manager who directly manages the employee's branch" do
      expect(subject.new(manager, line_item).waive?).to be true
    end

    it "denies employee" do
      expect(subject.new(employee, line_item).waive?).to be false
    end

    context "branch_manager who does not manage the employee's branch" do
      let(:other_branch)  { create(:branch, business: business) }
      let(:other_manager) { create(:user, :branch_manager, business: business) }

      before { create(:user_branch, user: other_manager, branch: other_branch) }

      it "denies the manager" do
        expect(subject.new(other_manager, line_item).waive?).to be false
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
  end
end
