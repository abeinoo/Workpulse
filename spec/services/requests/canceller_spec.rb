require "rails_helper"

RSpec.describe Requests::Canceller do
  let(:business)  { create(:business) }
  let(:manager)   { create(:user, :branch_manager, business: business) }
  let(:employee)  { create(:user, business: business) }

  describe "pending -> cancelled (no side-effects to reverse)" do
    it "cancels a pending late_permission request and audits it" do
      request = create(:employee_request, :late_permission, user: employee)

      result = described_class.cancel(request: request, cancelled_by: employee, reason: "No longer needed")

      expect(result).to be_success
      request.reload
      expect(request.status).to eq("cancelled")
      expect(request.cancelled_by).to eq(employee)
      expect(request.cancelled_at).to be_present
      expect(request.cancellation_reason).to eq("No longer needed")
      expect(AuditLog.where(auditable: request, action: "cancel").count).to eq(1)
    end

    it "cancels a pending salary_advance request" do
      request = create(:employee_request, :salary_advance, user: employee)
      result = described_class.cancel(request: request, cancelled_by: employee, reason: "Changed my mind")
      expect(result).to be_success
      expect(request.reload.status).to eq("cancelled")
    end

    it "cancels a pending punch_correction request without touching attendance" do
      work_date = Date.current - 1.day
      attendance = create(:attendance_record, user: employee, date: work_date, work_date: work_date,
                          check_in_at: Time.zone.local(work_date.year, work_date.month, work_date.day, 9, 0),
                          check_out_at: nil, status: "incomplete")
      request = create(:employee_request, :punch_correction, user: employee,
                       requested_for_date: work_date, correction_type: "missing_check_out",
                       proposed_time: "17:00")

      result = described_class.cancel(request: request, cancelled_by: employee, reason: "Mistake")

      expect(result).to be_success
      expect(attendance.reload.check_out_at).to be_nil
    end
  end

  describe "approved -> cancelled" do
    it "does not create an Advance when cancelling an approved salary_advance (Advance only created at pay)" do
      request = create(:employee_request, :salary_advance, :approved, user: employee)
      expect {
        described_class.cancel(request: request, cancelled_by: manager, reason: "Reconsidered")
      }.not_to change(Advance, :count)
      expect(request.reload.status).to eq("cancelled")
    end

    context "early_leave with an open payroll period" do
      let(:branch) { create(:branch, business: business) }
      let(:shift) do
        create(:shift, :fixed_time, business: business,
               start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
      end
      let!(:shift_assignment) do
        create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: 6.months.ago.to_date)
      end
      let!(:salary_profile) do
        create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: 6.months.ago.to_date)
      end
      let(:period) do
        create(:payroll_period, business: business, period_year: Date.current.year,
               period_month: Date.current.month, working_days: 22, status: "under_review")
      end
      let(:work_date) { period.period_start.next_occurring(:monday) }
      let!(:penalty_rule) do
        create(:penalty_rule, shift: shift, rule_type: "early_leave", threshold_minutes: 30,
               deduction_type: "percentage_of_daily", deduction_value: 50)
      end
      let!(:attendance) do
        create(:attendance_record, user: employee, branch: branch, shift_assignment: shift_assignment,
               date: work_date, work_date: work_date,
               check_in_at: Time.zone.local(work_date.year, work_date.month, work_date.day, 9, 0),
               check_out_at: Time.zone.local(work_date.year, work_date.month, work_date.day, 15, 0),
               worked_minutes: 360, early_leave_minutes: 120, late_minutes: 0, status: "early_leave")
      end
      let!(:entry) { create(:payroll_entry, payroll_period: period, user: employee, base_salary: 8_800, net_salary: 8_600) }
      let!(:request) do
        create(:employee_request, :early_leave, :approved,
               user: employee, requested_for_date: work_date, duration_minutes: 120)
      end

      before do
        # Simulate PermissionApplier having fully absorbed the penalty at approval time.
        entry.payroll_line_items.where(item_type: "early_leave_penalty",
                                       source_type: "AttendanceRecord", source_id: attendance.id).destroy_all
        entry.recalculate_totals!
      end

      it "restores the early_leave_penalty line item and recalculates totals" do
        expect {
          described_class.cancel(request: request, cancelled_by: manager, reason: "Approved by mistake")
        }.to change(PayrollLineItem, :count).by(1)

        entry.reload
        restored = entry.payroll_line_items.find_by(item_type: "early_leave_penalty",
                                                     source_type: "AttendanceRecord", source_id: attendance.id)
        expect(restored).to be_present
        expect(restored.amount).to eq(-200.0)
        expect(entry.total_deductions).to be > 0
        expect(request.reload.status).to eq("cancelled")
      end

      it "refuses to cancel once the payroll period is finalized" do
        period.update!(status: "finalized")

        result = described_class.cancel(request: request, cancelled_by: manager, reason: "Too late")

        expect(result).not_to be_success
        expect(request.reload.status).to eq("approved")
      end

      it "refuses to cancel once the payroll period is paid" do
        period.update!(status: "paid")

        result = described_class.cancel(request: request, cancelled_by: manager, reason: "Too late")

        expect(result).not_to be_success
        expect(request.reload.status).to eq("approved")
      end
    end

    context "punch_correction" do
      let(:work_date) { Date.current - 1.day }
      let(:original_check_out) do
        Time.zone.local(work_date.year, work_date.month, work_date.day, 17, 0)
      end
      let!(:attendance) do
        create(:attendance_record, user: employee, date: work_date, work_date: work_date,
               check_in_at: Time.zone.local(work_date.year, work_date.month, work_date.day, 9, 0),
               check_out_at: original_check_out, check_out_source: "manual",
               worked_minutes: 480, status: "present")
      end
      let!(:request) do
        create(:employee_request, :punch_correction, :approved, user: employee,
               requested_for_date: work_date, correction_type: "wrong_check_out_time",
               proposed_time: "18:30",
               original_check_out_at: original_check_out, original_check_out_source: "manual")
      end

      before do
        # Simulate PunchCorrectionApplier having already moved check_out_at at approval time.
        attendance.update_columns(
          check_out_at: Time.zone.local(work_date.year, work_date.month, work_date.day, 18, 30)
        )
      end

      it "restores the original check_out_at from the snapshot" do
        result = described_class.cancel(request: request, cancelled_by: manager, reason: "Wrong correction")

        expect(result).to be_success
        expect(attendance.reload.check_out_at).to eq(original_check_out)
        expect(request.reload.status).to eq("cancelled")
      end
    end
  end

  describe "terminal states" do
    it "refuses to cancel a rejected request" do
      request = create(:employee_request, :rejected, user: employee)
      result = described_class.cancel(request: request, cancelled_by: employee, reason: "x")
      expect(result).not_to be_success
      expect(request.reload.status).to eq("rejected")
    end

    it "refuses to cancel a paid salary_advance" do
      request = create(:employee_request, :salary_advance, :approved, user: employee)
      Requests::Approver.pay(request: request, paid_by: manager)
      expect(request.reload.status).to eq("paid")

      result = described_class.cancel(request: request, cancelled_by: manager, reason: "x")
      expect(result).not_to be_success
      expect(request.reload.status).to eq("paid")
    end

    it "refuses to cancel an already-cancelled request" do
      request = create(:employee_request, user: employee)
      described_class.cancel(request: request, cancelled_by: employee, reason: "first")

      result = described_class.cancel(request: request, cancelled_by: employee, reason: "second")
      expect(result).not_to be_success
    end
  end

  # Requests::Canceller locks the request row for every request type and
  # re-checks the committed state against the status the caller saw (F-A1 for
  # salary advances and punch corrections, F-A7 for every other type). These are
  # single-connection examples; the genuine two-connection races are in
  # spec/services/requests/advance_payment_concurrency_spec.rb.
  describe "status changed out from under a cancel attempt" do
    it "cleanly refuses when the request was rejected first" do
      request = create(:employee_request, user: employee)
      Requests::Approver.reject(request: request, reviewed_by: manager)

      result = described_class.cancel(request: request, cancelled_by: employee, reason: "too late")

      expect(result).not_to be_success
      expect(request.reload.status).to eq("rejected")
    end

    it "refuses a stale pending copy of a permission approved since (it would skip reverting the approval's effect)" do
      request = create(:employee_request, :late_permission, user: employee)
      stale   = EmployeeRequest.find(request.id) # loaded while pending
      expect(Requests::Approver.approve(request: EmployeeRequest.find(request.id), reviewed_by: manager)).to be_success
      allow(Requests::PermissionPayrollEffects).to receive(:permission_cancelled).and_call_original

      result = described_class.cancel(request: stale, cancelled_by: employee, reason: "too late")

      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("requests.errors.cannot_cancel"))
      expect(request.reload).to have_attributes(status: "approved", cancelled_at: nil)
      expect(Requests::PermissionPayrollEffects).not_to have_received(:permission_cancelled)
      expect(AuditLog.where(auditable: request).pluck(:action)).to eq(%w[approve])
    end
  end
end
