require "rails_helper"

# Characterization (Pilot 5, M1) — CURRENT visibility through one real policy
# scope per consuming domain, resolved with Pundit exactly as controllers do.
# These stand in for the API scope specs that fail on main for unrelated
# reasons (payroll_waive_scope_spec: missing waive?; payroll_visibility_spec:
# response shape) and pin how Workforce membership reaches each domain:
# * Workforce            — UserPolicy::Scope            (EmployeeScope)
# * Attendance & Payroll — PayrollEntryPolicy::Scope    (EmployeeScope)
# * Finance & Sales      — ExpensePolicy::Scope         (BranchScope, management only)
# * Inventory / Laundry  — TowelTransferPolicy::Scope   (BranchScope + shift assignments)
RSpec.describe "Characterization: membership through real policy scopes" do
  let(:business)       { create(:business) }
  let(:other_business) { create(:business) }
  let!(:owner)         { create(:user, :owner, business: business) }
  let(:shift)          { create(:shift, :hour_based, business: business) }
  let(:branch_a)       { create(:branch, business: business, name: "A") }
  let(:branch_b)       { create(:branch, business: business, name: "B") }
  let(:branch_c)       { create(:branch, business: business, name: "C") }

  def assign(user, branch) = create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: 1.month.ago.to_date)
  def cover(user, branch)  = create(:shift_assignment, :temporary_coverage, user: user, branch: branch, shift: shift)

  def user_with(permissions = [], scopes: {})
    user = create(:user, business: business)
    return user if permissions.empty?

    role = create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes)
    user.update_column(:permission_role_id, role.id)
    user.reload
  end

  def visible(user, model) = Pundit.policy_scope!(user, model)

  describe "Workforce: UserPolicy::Scope" do
    let!(:member)   { user_with.tap { |u| assign(u, branch_a) } }
    let!(:covering) { user_with.tap { |u| assign(u, branch_b); cover(u, branch_a) } }
    let!(:outside)  { user_with.tap { |u| assign(u, branch_b) } }
    let!(:foreign)  { create(:user, business: other_business) }

    it "branch-scoped view_employees: self + members of the managed branch (regular and covering)" do
      manager = user_with(%w[view_employees], scopes: { "view_employees" => "branch" })
      branch_a.update!(branch_manager: manager)

      expect(visible(manager, User)).to contain_exactly(manager, member, covering)
    end

    it "no configured scope: self + the hierarchy (managed and area-managed branches)" do
      regional = user_with(%w[view_employees])
      [ branch_a, branch_b ].each { |b| b.update!(area_manager: regional) }

      expect(visible(regional, User)).to contain_exactly(regional, member, covering, outside)
    end

    it "an ordinary employee working in the branch sees only themselves" do
      worker = user_with(%w[view_employees], scopes: { "view_employees" => "branch" })
      assign(worker, branch_a)

      expect(visible(worker, User)).to contain_exactly(worker)
    end

    it "without view_employees: only themselves; the owner: every user of the business, never another business" do
      expect(visible(member, User)).to contain_exactly(member)
      expect(visible(owner, User)).to include(owner, member, covering, outside)
      expect(visible(owner, User)).not_to include(foreign)
    end
  end

  describe "Attendance & Payroll: PayrollEntryPolicy::Scope" do
    let(:period)       { create(:payroll_period, business: business, period_year: 2026, period_month: 6, status: "draft") }
    let(:paid_period)  { create(:payroll_period, business: business, period_year: 2026, period_month: 5, status: "paid") }
    let(:foreign_period) { create(:payroll_period, business: other_business, period_year: 2026, period_month: 6) }
    let(:member)  { user_with.tap { |u| assign(u, branch_a) } }
    let(:covering) { user_with.tap { |u| assign(u, branch_b); cover(u, branch_a) } }
    let(:outside) { user_with.tap { |u| assign(u, branch_b) } }

    def entry(user, on: period) = create(:payroll_entry, payroll_period: on, user: user)

    it "branch-scoped view_payroll: entries of the managed branch's members (incl. covering) plus the viewer's own" do
      manager = user_with(%w[view_payroll], scopes: { "view_payroll" => "branch" })
      branch_a.update!(branch_manager: manager)
      mine, theirs, covered, not_mine = entry(manager), entry(member), entry(covering), entry(outside)
      entry(create(:user, business: other_business), on: foreign_period)

      expect(visible(manager, PayrollEntry)).to contain_exactly(mine, theirs, covered)
      expect(visible(manager, PayrollEntry)).not_to include(not_mine)
    end

    it "no configured scope: the hierarchy only, without the viewer's own entry" do
      manager = user_with(%w[view_payroll])
      branch_a.update!(branch_manager: manager)
      mine, theirs = entry(manager), entry(member)

      expect(visible(manager, PayrollEntry)).to contain_exactly(theirs)
      expect(visible(manager, PayrollEntry)).not_to include(mine)
    end

    it "without view_payroll: only the user's own entries of finalized/paid periods" do
      draft_entry, paid_entry = entry(member), entry(member, on: paid_period)
      entry(outside, on: paid_period)

      expect(visible(member, PayrollEntry)).to contain_exactly(paid_entry)
      expect(visible(member, PayrollEntry)).not_to include(draft_entry)
    end
  end

  describe "Finance & Sales: ExpensePolicy::Scope (management-based BranchScope)" do
    let(:manager) { user_with(%w[view_expenses], scopes: { "view_expenses" => "branch" }) }
    let!(:in_a)   { create(:expense, business: business, branch: branch_a) }
    let!(:in_b)   { create(:expense, business: business, branch: branch_b) }
    let!(:foreign) { create(:expense, business: other_business) }

    before { branch_a.update!(branch_manager: manager) }

    it "branch scope: managed-branch expenses plus the viewer's own, not other branches" do
      own_b = create(:expense, business: business, branch: branch_b, created_by: manager)

      expect(visible(manager, Expense)).to contain_exactly(in_a, own_b)
    end

    it "does not use membership: working (assigned) in another branch adds nothing" do
      assign(manager, branch_b)

      expect(visible(manager, Expense)).to contain_exactly(in_a)
    end

    it "owner: every expense of the business; no expense permission: nothing" do
      expect(visible(owner, Expense)).to contain_exactly(in_a, in_b)
      expect(visible(user_with, Expense)).to be_empty
    end
  end

  describe "Inventory / Laundry: TowelTransferPolicy::Scope (BranchScope + shift assignments)" do
    let(:laundry) { create(:branch, business: business, branch_type: "laundry", name: "L") }
    let!(:from_a) { transfer(branch_a) }
    let!(:from_b) { transfer(branch_b) }
    let!(:from_c) { transfer(branch_c) }

    def transfer(source)
      towel_type = business.towel_types.first || business.towel_types.create!(name: "Bath Towel")
      business.towel_transfers.create!(
        source_branch: source, destination_branch: laundry, towel_status: "dirty",
        items: [ TowelTransferItem.new(towel_type: towel_type, declared_quantity: 5) ]
      )
    end

    def receptionist(scope) = user_with(%w[view_towel_balances], scopes: { "view_towel_balances" => scope })

    it "branch scope resolves from the user's assignments (regular and covering), not management" do
      staff = receptionist("branch")
      assign(staff, branch_a)
      cover(staff, branch_b)

      expect(visible(staff, TowelTransfer)).to contain_exactly(from_a, from_b)
    end

    it "area scope expands through the assigned branch's area manager" do
      staff = receptionist("area")
      regional = user_with
      [ branch_a, branch_c ].each { |b| b.update!(area_manager: regional) }
      assign(staff, branch_a)

      expect(visible(staff, TowelTransfer)).to contain_exactly(from_a, from_c)
    end

    it "matches the destination side too, and is empty without any assignment" do
      staff = receptionist("branch")
      expect(visible(staff, TowelTransfer)).to be_empty

      assign(staff, laundry)
      expect(visible(staff, TowelTransfer)).to contain_exactly(from_a, from_b, from_c)
    end

    it "management still counts alongside membership; owner sees all; no permission sees nothing" do
      manager = receptionist("branch")
      branch_c.update!(branch_manager: manager)
      assign(manager, branch_a)

      expect(visible(manager, TowelTransfer)).to contain_exactly(from_a, from_c)
      expect(visible(owner, TowelTransfer)).to contain_exactly(from_a, from_b, from_c)
      expect(visible(user_with, TowelTransfer)).to be_empty
    end
  end
end
