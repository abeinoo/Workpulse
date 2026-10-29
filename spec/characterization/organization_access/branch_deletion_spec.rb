require "rails_helper"

# OA-6 / BUG-026 — regression. The same scenarios that
# characterized the original defect (commit "test: characterize branch
# lifecycle data integrity") now pin the adopted behaviour: deleting a branch
# never removes history, the outcome shown is the real one, and only a
# completed deletion is audited. Full lifecycle coverage (deactivation, the
# last-active-branch rule, concurrency, inactive-branch use) lives in
# spec/services/organization_access/branch_lifecycle*_spec.rb and
# spec/requests/admin/branch_lifecycle_spec.rb.
RSpec.describe "Branch deletion — history is never deleted (OA-6 / BUG-026)", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business, name: "Doomed Branch") }
  let!(:main_branch) { create(:branch, business: business, name: "Main") }
  let(:employee) { create(:user, business: business) }

  # Attendance history: a checked-out day and the raw device punch behind it.
  # The factory attaches a shift assignment at the branch.
  let!(:attendance_record) do
    create(:attendance_record, :checked_out, business: business, user: employee, branch: branch)
  end
  let!(:punch_log) do
    create(:biometric_punch_log, business: business, employee: employee, attendance_record: attendance_record)
  end

  before { sign_in owner }

  def delete_branch
    delete admin_branch_path(branch), params: { reason: "Closing this location" }
  end

  def refused_with_history!
    expect(response).to redirect_to(admin_branch_path(branch))
    expect(flash[:alert]).to eq(I18n.t("admin.branches.lifecycle.errors.has_history"))
    expect(flash[:notice]).to be_nil
    expect(Branch.exists?(branch.id)).to be(true)
  end

  context "when the branch has only attendance history (no financial records)" do
    it "refuses the deletion and says why" do
      delete_branch

      refused_with_history!
    end

    it "keeps the attendance records and the raw device punches" do
      expect { delete_branch }
        .to not_change { AttendanceRecord.where(id: attendance_record.id).count }
        .and not_change { BiometricPunchLog.where(id: punch_log.id).count }
    end

    it "keeps the shift assignment's branch" do
      assignment = attendance_record.shift_assignment

      expect { delete_branch }.not_to change { assignment.reload.branch_id }.from(branch.id)
    end

    it "writes no deletion audit entry" do
      expect { delete_branch }.not_to change(AuditLog.where(action: "destroy"), :count)
    end
  end

  context "when a legacy branch-linked payroll period exists" do
    let!(:period) { create(:payroll_period, :finalized, business: business, branch: branch) }
    let!(:entry)  { create(:payroll_entry, payroll_period: period, user: employee) }
    let!(:item)   { create(:payroll_line_item, payroll_entry: entry) }

    it "keeps the finalized period with its entries and line items" do
      expect { delete_branch }
        .to not_change { PayrollPeriod.where(id: period.id).count }
        .and not_change { PayrollEntry.where(id: entry.id).count }
        .and not_change { PayrollLineItem.where(id: item.id).count }
      refused_with_history!
    end
  end

  context "when an attendance record carries a manager correction" do
    let!(:attendance_adjustment) { create(:attendance_adjustment, attendance_record: attendance_record) }

    it "keeps everything and no longer claims the branch was removed" do
      delete_branch

      refused_with_history!
      expect(AttendanceAdjustment.exists?(attendance_adjustment.id)).to be(true)
    end
  end

  context "when the branch also has financial history guarded by restrict_with_error" do
    let!(:expense) { create(:expense, business: business, branch: branch) }

    it "keeps everything and no longer claims the branch was removed" do
      delete_branch

      refused_with_history!
      expect(Expense.exists?(expense.id)).to be(true)
    end
  end

  context "when a table references the branch by foreign key only (daily reconciliation)" do
    before { DailyReconciliation.create_for!(branch: branch) }

    it "is refused cleanly (no error page) and rolls back every cascade" do
      delete_branch

      refused_with_history!
      expect(AttendanceRecord.exists?(attendance_record.id)).to be(true)
      expect(BiometricPunchLog.exists?(punch_log.id)).to be(true)
    end
  end
end
