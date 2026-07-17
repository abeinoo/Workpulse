require "rails_helper"

RSpec.describe ExpensePolicy, type: :policy do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:br1)      { create(:branch, business: business) }
  let(:br2)      { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }

  # Manager who branch-manages br1, scoped to "branch"
  let(:manager) do
    role = create(:permission_role, business: business,
                  permissions: %w[view_expenses create_expenses edit_expenses approve_expenses],
                  permission_scopes: { "view_expenses" => "branch" })
    u = create(:user, business: business, permission_role: role)
    br1.update!(branch_manager_id: u.id)
    u
  end

  describe "#create? branch write-scope" do
    it "allows creating an expense for a branch the manager oversees" do
      expense = build(:expense, business: business, branch: br1, expense_category: category)
      expect(described_class.new(manager, expense).create?).to be true
    end

    it "DENIES creating an expense for a branch outside the manager's scope" do
      expense = build(:expense, business: business, branch: br2, expense_category: category)
      expect(described_class.new(manager, expense).create?).to be false
    end

    it "ALLOWS a business-level (branchless) request — it attributes to no branch" do
      expense = build(:expense, business: business, branch: nil, expense_category: category)
      expect(described_class.new(manager, expense).create?).to be true
    end

    it "allows the owner to create for any branch" do
      expense = build(:expense, business: business, branch: br2, expense_category: category)
      expect(described_class.new(owner, expense).create?).to be true
    end

    it "still permits the blank new form (no branch chosen yet)" do
      expect(described_class.new(manager, Expense.new(business: business)).new?).to be true
    end
  end

  # The exact bug reported: the "New Expense" button is gated by a CLASS-level
  # policy check, which must not depend on instance state.
  describe "class-level button checks (Expense class, not an instance)" do
    it "new? is true for anyone with create_expenses (owner, manager)" do
      expect(described_class.new(owner, Expense).new?).to be true
      expect(described_class.new(manager, Expense).new?).to be true
    end

    it "create? on the bare class does not error and is false (use new? for buttons)" do
      expect { described_class.new(owner, Expense).create? }.not_to raise_error
      expect(described_class.new(owner, Expense).create?).to be false
    end
  end

  describe "full create workflow by role" do
    it "lets the OWNER create (any branch or branchless)" do
      expect(described_class.new(owner, build(:expense, business: business, branch: br1)).create?).to be true
      expect(described_class.new(owner, build(:expense, business: business, branch: nil)).create?).to be true
    end

    it "lets a plain EMPLOYEE with create_expenses raise a branchless request" do
      role = create(:permission_role, business: business, permissions: %w[view_expenses create_expenses])
      employee = create(:user, business: business, permission_role: role) # manages no branch
      req = build(:expense, business: business, branch: nil, expense_category: category, created_by: employee)
      expect(described_class.new(employee, Expense).new?).to be true     # button shows
      expect(described_class.new(employee, req).create?).to be true       # can submit
    end

    it "blocks a user WITHOUT create_expenses" do
      role = create(:permission_role, business: business, permissions: %w[view_expenses])
      viewer = create(:user, business: business, permission_role: role)
      expect(described_class.new(viewer, Expense).new?).to be false
      expect(described_class.new(viewer, build(:expense, business: business)).create?).to be false
    end
  end

  describe "#approve? self-approval" do
    it "blocks approving an expense you created; allows another approver" do
      mine = create(:expense, :pending, business: business, branch: br1, created_by: manager)
      expect(described_class.new(manager, mine).approve?).to be false
      expect(described_class.new(owner, mine).approve?).to be true
    end

    it "lets the business owner approve their OWN expense (owner exception)" do
      owners_own = create(:expense, :pending, business: business, branch: br1, created_by: owner)
      expect(described_class.new(owner, owners_own).approve?).to be true
    end
  end

  describe "Scope (reporting/listing visibility)" do
    it "shows in-scope, own-created, and shared-allocated expenses but hides other branches" do
      in_scope   = create(:expense, business: business, branch: br1)
      out_scope  = create(:expense, business: business, branch: br2)
      shared     = build(:expense, business: business, branch: nil, amount: 100, distribution_method: "percentage")
      shared.expense_allocations.build(branch: br1, allocation_percentage: 100, allocated_amount: 100)
      shared.save!

      visible = ExpensePolicy::Scope.new(manager, Expense).resolve
      expect(visible).to include(in_scope, shared)
      expect(visible).not_to include(out_scope)
    end

    it "shows everything to the owner" do
      e1 = create(:expense, business: business, branch: br1)
      e2 = create(:expense, business: business, branch: br2)
      expect(ExpensePolicy::Scope.new(owner, Expense).resolve).to include(e1, e2)
    end
  end
end
