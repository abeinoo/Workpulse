require "rails_helper"

# OA-6 (SaaS audit Phase 1, 2026-10-29) — CHARACTERIZATION ONLY.
#
# Pins what deleting a branch does TODAY to the history attached to it
# (Admin::BranchesController#destroy → Branch#destroy). Nothing here is the
# desired behaviour: the examples marked "data loss" / "misreport" describe a
# defect recorded in docs/quality/deferred-bugs.md and are expected to change
# once an approved fix lands. Deletion behaviour is deliberately NOT changed in
# P0 — see the register entry for the open decisions.
#
# Branch associations involved (app/models/branch.rb):
#   has_many :attendance_records, dependent: :destroy   → AttendanceRecord also
#     destroys its attendance_adjustments and biometric_punch_logs
#   has_many :payroll_periods,    dependent: :destroy   → PayrollPeriod also
#     destroys payroll_entries (→ payroll_line_items), branch reviews,
#     obligation deductions and snapshots
#   has_many :shift_assignments,  dependent: :nullify
#   has_many :expenses, … dependent: :restrict_with_error (financial history)
# Tables that reference branches by FK only (e.g. daily_reconciliations,
# stock_issues) have no association on Branch, so the database refuses the
# delete (ActiveRecord::InvalidForeignKey) and the transaction rolls back.
RSpec.describe "Branch deletion — effect on history (OA-6 characterization)", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business, name: "Doomed Branch") }
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
    delete admin_branch_path(branch)
  end

  context "when the branch has only attendance history (no financial records)" do
    it "reports success and removes the branch" do
      delete_branch

      expect(response).to redirect_to(admin_branches_path)
      expect(flash[:notice]).to eq(I18n.t("flash.branch_removed"))
      expect(Branch.exists?(branch.id)).to be(false)
    end

    it "hard-deletes the attendance records and the raw device punches (data loss)" do
      expect { delete_branch }
        .to change { AttendanceRecord.where(id: attendance_record.id).count }.from(1).to(0)
        .and change { BiometricPunchLog.where(id: punch_log.id).count }.from(1).to(0)
    end

    it "keeps the shift assignment but erases which branch it was at" do
      assignment = attendance_record.shift_assignment

      expect { delete_branch }.to change { assignment.reload.branch_id }.from(branch.id).to(nil)
    end

    it "writes no audit entry for the deletion" do
      expect { delete_branch }.not_to change(AuditLog, :count)
    end
  end

  context "when a legacy branch-linked payroll period exists" do
    let!(:period) { create(:payroll_period, :finalized, business: business, branch: branch) }
    let!(:entry)  { create(:payroll_entry, payroll_period: period, user: employee) }
    let!(:item)   { create(:payroll_line_item, payroll_entry: entry) }

    it "hard-deletes the finalized period with its entries and line items (data loss)" do
      expect { delete_branch }
        .to change { PayrollPeriod.where(id: period.id).count }.from(1).to(0)
        .and change { PayrollEntry.where(id: entry.id).count }.from(1).to(0)
        .and change { PayrollLineItem.where(id: item.id).count }.from(1).to(0)
    end
  end

  # An attendance record with a manager correction cannot be destroyed
  # (AttendanceAdjustment's before_destroy aborts — adjustments are immutable),
  # which aborts the whole branch destroy.
  context "when an attendance record carries a manager correction" do
    let!(:attendance_adjustment) { create(:attendance_adjustment, attendance_record: attendance_record) }

    it "keeps the branch and all history" do
      delete_branch

      expect(Branch.exists?(branch.id)).to be(true)
      expect(AttendanceRecord.exists?(attendance_record.id)).to be(true)
      expect(AttendanceAdjustment.exists?(attendance_adjustment.id)).to be(true)
      expect(BiometricPunchLog.exists?(punch_log.id)).to be(true)
      expect(attendance_record.shift_assignment.reload.branch_id).to eq(branch.id)
    end

    it "still tells the user the branch was removed (misreport — the destroy result is ignored)" do
      delete_branch

      expect(response).to redirect_to(admin_branches_path)
      expect(flash[:notice]).to eq(I18n.t("flash.branch_removed"))
    end
  end

  context "when the branch also has financial history guarded by restrict_with_error" do
    let!(:expense) { create(:expense, business: business, branch: branch) }

    it "keeps the branch and all history" do
      delete_branch

      expect(Branch.exists?(branch.id)).to be(true)
      expect(AttendanceRecord.exists?(attendance_record.id)).to be(true)
      expect(BiometricPunchLog.exists?(punch_log.id)).to be(true)
      expect(attendance_record.shift_assignment.reload.branch_id).to eq(branch.id)
    end

    it "still tells the user the branch was removed (misreport — the destroy result is ignored)" do
      delete_branch

      expect(response).to redirect_to(admin_branches_path)
      expect(flash[:notice]).to eq(I18n.t("flash.branch_removed"))
    end
  end

  context "when a table references the branch by foreign key only (daily reconciliation)" do
    before { DailyReconciliation.create_for!(branch: branch) }

    it "is refused by the database and rolls back every cascade" do
      expect { branch.destroy }.to raise_error(ActiveRecord::InvalidForeignKey)

      expect(Branch.exists?(branch.id)).to be(true)
      expect(AttendanceRecord.exists?(attendance_record.id)).to be(true)
      expect(BiometricPunchLog.exists?(punch_log.id)).to be(true)
    end
  end
end
