require "rails_helper"

# BUG-026 — adopted branch lifecycle: deactivate instead of delete, keep at least
# one active branch, delete only a never-used branch, audit every completed
# transition and nothing else.
RSpec.describe "Branch lifecycle services (BUG-026)" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business, name: "Retiring", active: true) }
  let!(:other_active_branch) { create(:branch, business: business, name: "Main", active: true) }
  let(:employee) { create(:user, business: business) }

  def deactivate(id = branch.id, actor: owner, reason: "Closed for renovation")
    OrganizationAccess::DeactivateBranch.new(id, actor: actor, reason: reason).call
  end

  def reactivate(id = branch.id, actor: owner, reason: nil)
    OrganizationAccess::ReactivateBranch.new(id, actor: actor, reason: reason).call
  end

  def delete_branch(id = branch.id, actor: owner, reason: "Created by mistake")
    OrganizationAccess::DeleteBranch.new(id, actor: actor, reason: reason).call
  end

  def branch_audits(action = nil)
    scope = AuditLog.where(auditable_type: "Branch", auditable_id: branch.id)
    action ? scope.where(action: action) : scope
  end

  # Attendance + raw punch + legacy branch-linked payroll + an expense + the
  # shift assignment the attendance factory creates at the branch.
  def with_history
    record = create(:attendance_record, :checked_out, business: business, user: employee, branch: branch)
    punch  = create(:biometric_punch_log, business: business, employee: employee, attendance_record: record)
    period = create(:payroll_period, :finalized, business: business, branch: branch)
    entry  = create(:payroll_entry, payroll_period: period, user: employee)
    item   = create(:payroll_line_item, payroll_entry: entry)
    expense = create(:expense, business: business, branch: branch)
    { record: record, punch: punch, period: period, entry: entry, item: item, expense: expense,
      assignment: record.shift_assignment }
  end

  describe OrganizationAccess::DeactivateBranch do
    it "deactivates the branch and keeps every historical record and branch reference" do
      history = with_history

      result = deactivate

      expect(result).to be_ok
      expect(branch.reload).not_to be_active
      expect(AttendanceRecord.find(history[:record].id).branch_id).to eq(branch.id)
      expect(BiometricPunchLog.exists?(history[:punch].id)).to be(true)
      expect(PayrollPeriod.find(history[:period].id).branch_id).to eq(branch.id)
      expect(PayrollEntry.exists?(history[:entry].id)).to be(true)
      expect(PayrollLineItem.exists?(history[:item].id)).to be(true)
      expect(Expense.find(history[:expense].id).branch_id).to eq(branch.id)
      expect(history[:assignment].reload.branch_id).to eq(branch.id)
    end

    it "writes one audit entry with the actor, business, change and reason" do
      expect(deactivate).to be_ok

      audit = branch_audits("deactivate").sole
      expect(audit.actor).to eq(owner)
      expect(audit.business_id).to eq(business.id)
      expect(audit.changes_json).to eq("active" => [ true, false ])
      expect(audit.metadata).to include("reason" => "Closed for renovation", "branch_name" => "Retiring")
    end

    it "requires a reason" do
      result = deactivate(reason: "  ")

      expect(result.error).to eq(:reason_required)
      expect(branch.reload).to be_active
      expect(branch_audits).to be_empty
    end

    it "refuses to deactivate the last active branch" do
      other_active_branch.update_column(:active, false)

      result = deactivate

      expect(result.error).to eq(:last_active_branch)
      expect(branch.reload).to be_active
      expect(branch_audits).to be_empty
    end

    it "refuses an already inactive branch without a second audit entry" do
      branch.update_column(:active, false)

      expect(deactivate.error).to eq(:already_inactive)
      expect(branch_audits).to be_empty
    end

    it "rolls back when the audit entry cannot be written" do
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "audit insert failed")

      result = deactivate

      expect(result).not_to be_ok
      expect(result.error).to eq(:failed)
      expect(branch.reload).to be_active
    end

    it "refuses a user without manage_branches" do
      clerk = create(:user, business: business)

      expect(deactivate(actor: clerk).error).to eq(:not_authorized)
      expect(branch.reload).to be_active
      expect(branch_audits).to be_empty
    end

    it "cannot reach another business's branch" do
      foreign = create(:branch, business: create(:business))

      expect { deactivate(foreign.id) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(foreign.reload).to be_active
    end
  end

  describe OrganizationAccess::ReactivateBranch do
    before { branch.update_column(:active, false) }

    it "reactivates the branch and audits it" do
      result = reactivate(reason: "Reopened")

      expect(result).to be_ok
      expect(branch.reload).to be_active
      audit = branch_audits("reactivate").sole
      expect(audit.changes_json).to eq("active" => [ false, true ])
      expect(audit.metadata).to include("reason" => "Reopened")
    end

    it "refuses an already active branch without an audit entry" do
      branch.update_column(:active, true)

      expect(reactivate.error).to eq(:already_active)
      expect(branch_audits).to be_empty
    end
  end

  describe OrganizationAccess::DeleteBranch do
    it "deletes a never-used branch and audits a snapshot of it" do
      result = delete_branch

      expect(result).to be_ok
      expect(Branch.exists?(branch.id)).to be(false)
      audit = branch_audits("destroy").sole
      expect(audit.actor).to eq(owner)
      expect(audit.metadata).to include("name" => "Retiring", "branch_type" => "sales", "reason" => "Created by mistake")
    end

    it "refuses a branch with history and keeps everything" do
      history = with_history

      result = delete_branch

      expect(result.error).to eq(:has_history)
      expect(Branch.exists?(branch.id)).to be(true)
      expect(AttendanceRecord.exists?(history[:record].id)).to be(true)
      expect(BiometricPunchLog.exists?(history[:punch].id)).to be(true)
      expect(PayrollPeriod.exists?(history[:period].id)).to be(true)
      expect(PayrollLineItem.exists?(history[:item].id)).to be(true)
      expect(history[:assignment].reload.branch_id).to eq(branch.id)
      expect(branch_audits).to be_empty
    end

    it "refuses a branch with attendance history only" do
      record = create(:attendance_record, :checked_out, business: business, user: employee, branch: branch)

      expect(delete_branch.error).to eq(:has_history)
      expect(AttendanceRecord.exists?(record.id)).to be(true)
      expect(record.shift_assignment.reload.branch_id).to eq(branch.id)
    end

    it "refuses a branch referenced only by a database foreign key, rolling everything back" do
      DailyReconciliation.create_for!(branch: branch)

      expect(delete_branch.error).to eq(:has_history)
      expect(Branch.exists?(branch.id)).to be(true)
      expect(branch_audits).to be_empty
    end

    it "refuses a branch that has lifecycle history (once deactivated)" do
      expect(deactivate).to be_ok

      expect(delete_branch.error).to eq(:has_history)
      expect(Branch.exists?(branch.id)).to be(true)
      expect(branch_audits.pluck(:action)).to eq([ "deactivate" ])
    end

    it "refuses to delete the last active branch" do
      other_active_branch.update_column(:active, false)

      expect(delete_branch.error).to eq(:last_active_branch)
      expect(Branch.exists?(branch.id)).to be(true)
    end

    it "requires a reason" do
      expect(delete_branch(reason: "").error).to eq(:reason_required)
      expect(Branch.exists?(branch.id)).to be(true)
    end

    it "refuses a user without manage_branches" do
      expect(delete_branch(actor: create(:user, business: business)).error).to eq(:not_authorized)
      expect(Branch.exists?(branch.id)).to be(true)
    end
  end
end
