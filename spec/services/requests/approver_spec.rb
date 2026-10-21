require "rails_helper"

RSpec.describe Requests::Approver do
  let(:business)   { create(:business) }
  let(:manager)    { create(:user, :branch_manager, business: business) }
  let(:accountant) { create(:user, :accountant, business: business) }

  describe ".approve" do
    context "late_permission request" do
      let!(:request) do
        create(:employee_request, :late_permission,
               user: create(:user, business: business))
      end

      it "returns success" do
        result = described_class.approve(request: request, reviewed_by: manager)
        expect(result).to be_success
      end

      it "transitions the request to :approved" do
        described_class.approve(request: request, reviewed_by: manager)
        expect(request.reload.status).to eq("approved")
      end

      it "records the reviewer and timestamp" do
        described_class.approve(request: request, reviewed_by: manager)
        expect(request.reload.reviewed_by).to eq(manager)
        expect(request.reload.reviewed_at).to be_present
      end

      it "does not create an Advance for non-salary requests" do
        expect {
          described_class.approve(request: request, reviewed_by: manager)
        }.not_to change(Advance, :count)
      end

      it "calls Payroll::PermissionApplier to retroactively update payroll" do
        allow(Payroll::PermissionApplier).to receive(:call)
        described_class.approve(request: request, reviewed_by: manager)
        expect(Payroll::PermissionApplier).to have_received(:call).with(request)
      end
    end

    context "salary_advance request" do
      let!(:request) do
        create(:employee_request, :salary_advance, amount: 1_500.0,
               user: create(:user, business: business))
      end

      it "transitions to approved but does NOT create an Advance" do
        expect {
          described_class.approve(request: request, reviewed_by: manager)
        }.not_to change(Advance, :count)
        expect(request.reload.status).to eq("approved")
      end
    end

    context "when the request is already approved" do
      let!(:request) { create(:employee_request, :approved,
                               user: create(:user, business: business)) }

      it "returns failure" do
        result = described_class.approve(request: request, reviewed_by: manager)
        expect(result).not_to be_success
        expect(result.error).to include("already")
      end
    end
  end

  describe ".reject" do
    let!(:request) do
      create(:employee_request, :late_permission,
             user: create(:user, business: business))
    end

    it "transitions the request to :rejected" do
      described_class.reject(request: request, reviewed_by: manager)
      expect(request.reload.status).to eq("rejected")
    end

    it "records the reviewer" do
      described_class.reject(request: request, reviewed_by: manager)
      expect(request.reload.reviewed_by).to eq(manager)
    end

    it "accepts an optional response_note" do
      described_class.reject(request: request, reviewed_by: manager,
                              response_note: "Not approved this period")
      expect(request.reload.response_note).to eq("Not approved this period")
    end

    context "when the request is already rejected" do
      let!(:rejected) { create(:employee_request, :rejected,
                                user: create(:user, business: business)) }

      it "returns failure" do
        result = described_class.reject(request: rejected, reviewed_by: manager)
        expect(result).not_to be_success
      end
    end
  end

  describe ".pay" do
    context "approved salary_advance request" do
      let!(:request) do
        create(:employee_request, :salary_advance, :approved, amount: 2_000.0,
               user: create(:user, business: business))
      end

      it "returns success" do
        result = described_class.pay(request: request, paid_by: accountant)
        expect(result).to be_success
      end

      it "transitions the request to :paid" do
        described_class.pay(request: request, paid_by: accountant)
        expect(request.reload.status).to eq("paid")
      end

      it "creates an Advance record for the full amount" do
        expect {
          described_class.pay(request: request, paid_by: accountant)
        }.to change(Advance, :count).by(1)

        advance = Advance.last
        expect(advance.total_amount).to eq(2_000.0)
        expect(advance.remaining_amount).to eq(2_000.0)
        expect(advance.user).to eq(request.user)
        expect(advance.employee_request).to eq(request)
        expect(advance.status).to eq("active")
      end
    end

    context "pending salary_advance request (not yet manager-approved)" do
      let!(:request) do
        create(:employee_request, :salary_advance, amount: 500.0,
               user: create(:user, business: business))
      end

      it "returns failure" do
        result = described_class.pay(request: request, paid_by: accountant)
        expect(result).not_to be_success
        expect(result.error).to include("approved")
      end
    end

    context "non-salary-advance request" do
      let!(:request) do
        create(:employee_request, :approved,
               user: create(:user, business: business))
      end

      it "returns failure" do
        result = described_class.pay(request: request, paid_by: accountant)
        expect(result).not_to be_success
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Punch correction approval
  # ──────────────────────────────────────────────────────────────
  describe ".approve — punch_correction request" do
    let(:employee)  { create(:user, business: business) }
    let(:work_date) { Date.current - 1.day }
    # business default timezone is Asia/Riyadh (UTC+3): 09:00 Riyadh = 06:00 UTC
    let(:check_in_local) { ActiveSupport::TimeZone["Asia/Riyadh"].local(work_date.year, work_date.month, work_date.day, 9, 0, 0) }
    let!(:attendance_record) do
      create(:attendance_record,
             user:           employee,
             date:           work_date,
             work_date:      work_date,
             check_in_at:    check_in_local,
             check_out_at:   nil,
             status:         "incomplete",
             worked_minutes: nil)
    end
    let!(:request) do
      create(:employee_request, :punch_correction,
             user:               employee,
             correction_type:    "missing_check_out",
             requested_for_date: work_date,
             proposed_time:      "17:00")
    end

    it "returns success" do
      result = described_class.approve(request: request, reviewed_by: manager)
      expect(result).to be_success
    end

    it "transitions the request to approved" do
      described_class.approve(request: request, reviewed_by: manager)
      expect(request.reload.status).to eq("approved")
    end

    it "sets check_out_at to 17:00 in the business timezone (Riyadh)" do
      described_class.approve(request: request, reviewed_by: manager)
      check_out_local = attendance_record.reload.check_out_at.in_time_zone("Asia/Riyadh")
      expect(check_out_local.hour).to eq(17)
      expect(check_out_local.min).to eq(0)
    end

    it "stores the reviewer's final punch as one datetime when a different time is given" do
      described_class.approve(
        request:       request,
        reviewed_by:   manager,
        approved_time: "16:45"
      )
      expect(request.reload.approved_punch_at)
        .to eq(ActiveSupport::TimeZone["Asia/Riyadh"].local(work_date.year, work_date.month, work_date.day, 16, 45))
      check_out_local = attendance_record.reload.check_out_at.in_time_zone("Asia/Riyadh")
      expect(check_out_local.hour).to eq(16)
      expect(check_out_local.min).to eq(45)
    end

    it "rolls back if PunchCorrectionApplier fails" do
      allow(Requests::PunchCorrectionApplier).to receive(:call).and_return(
        Requests::PunchCorrectionApplier::Result.new(success: false, error: "test error")
      )
      result = described_class.approve(request: request, reviewed_by: manager)
      expect(result).not_to be_success
      expect(request.reload.status).to eq("pending")
    end

    it "does not call Payroll::PermissionApplier" do
      allow(Payroll::PermissionApplier).to receive(:call)
      described_class.approve(request: request, reviewed_by: manager)
      expect(Payroll::PermissionApplier).not_to have_received(:call)
    end
  end

  # Direct service calls bypass the UI and the policy, so the rule is also enforced
  # here: the reviewer may never be the employee who submitted the request.
  describe "self-approval prevention" do
    let(:own_request) { create(:employee_request, :late_permission, user: manager) }

    it "allows an approver to approve ANOTHER user's request" do
      other_request = create(:employee_request, :late_permission,
                             user: create(:user, business: business))
      result = described_class.approve(request: other_request, reviewed_by: manager)
      expect(result).to be_success
      expect(other_request.reload.status).to eq("approved")
    end

    it "blocks approving your OWN request (direct service call)" do
      result = described_class.approve(request: own_request, reviewed_by: manager)
      expect(result).not_to be_success
      expect(result.error).to eq("You cannot approve or reject your own request.")
      expect(own_request.reload.status).to eq("pending")
    end

    it "blocks rejecting your OWN request (direct service call)" do
      result = described_class.reject(request: own_request, reviewed_by: manager)
      expect(result).not_to be_success
      expect(result.error).to eq("You cannot approve or reject your own request.")
      expect(own_request.reload.status).to eq("pending")
    end

    it "blocks self-approval of a punch correction (attendance correction)" do
      correction = create(:employee_request, :punch_correction, user: manager)
      result = described_class.approve(request: correction, reviewed_by: manager)
      expect(result).not_to be_success
      expect(result.error).to eq("You cannot approve or reject your own request.")
      expect(correction.reload.status).to eq("pending")
    end
  end

  # F-A7 — approve and reject lock the request row and re-check the committed
  # state, so a copy loaded before another transition committed cannot
  # overwrite it. (The genuine two-connection races are in
  # spec/services/requests/advance_payment_concurrency_spec.rb.)
  describe "a stale copy (another transition committed since it was loaded)" do
    let(:employee) { create(:user, business: business) }
    let(:other)    { create(:user, :branch_manager, business: business) }
    let!(:request) { create(:employee_request, :salary_advance, user: employee) }
    let!(:stale)   { EmployeeRequest.find(request.id) } # loaded while pending

    def fresh = EmployeeRequest.find(request.id)
    def audits = AuditLog.where(auditable: request).order(:id).pluck(:action)

    {
      "cancelled" => ->(req, by) { Requests::Canceller.cancel(request: req, cancelled_by: by, reason: "withdrawn") },
      "rejected"  => ->(req, by) { described_class.reject(request: req, reviewed_by: by) }
    }.each do |status, transition|
      it "refuses to approve it after it was #{status}; the #{status} state and its fields stand" do
        expect(transition.call(fresh, other)).to be_success

        result = described_class.approve(request: stale, reviewed_by: manager)

        expect(result).not_to be_success
        expect(result.error).to eq("Request is already #{status}")
        expect(fresh.status).to eq(status)
        expect(audits).not_to include("approve")
      end
    end

    it "refuses to approve it after it was approved and paid; the payment stands" do
      described_class.approve(request: fresh, reviewed_by: other)
      described_class.pay(request: fresh, paid_by: accountant)

      result = described_class.approve(request: stale, reviewed_by: manager)

      expect(result.error).to eq("Request is already paid")
      expect(fresh).to have_attributes(status: "paid", reviewed_by_id: accountant.id)
      expect(Advance.where(employee_request_id: request.id).count).to eq(1)
      expect(audits).to eq(%w[approve pay])
    end

    it "refuses a second approval: the first reviewer and audit stand" do
      described_class.approve(request: fresh, reviewed_by: other)

      expect(described_class.approve(request: stale, reviewed_by: manager).error).to eq("Request is already approved")
      expect(fresh.reviewed_by_id).to eq(other.id)
      expect(audits).to eq(%w[approve])
    end

    it "refuses to reject it after it was approved" do
      described_class.approve(request: fresh, reviewed_by: other)

      result = described_class.reject(request: stale, reviewed_by: manager)

      expect(result.error).to eq("Request is already approved")
      expect(fresh).to have_attributes(status: "approved", reviewed_by_id: other.id)
      expect(audits).to eq(%w[approve])
    end

    it "refuses to reject it after it was cancelled" do
      Requests::Canceller.cancel(request: fresh, cancelled_by: employee, reason: "withdrawn")

      result = described_class.reject(request: stale, reviewed_by: manager)

      expect(result.error).to eq("Request is already cancelled")
      expect(fresh.status).to eq("cancelled")
      expect(audits).to eq(%w[cancel])
    end
  end

  # F-A7 — standard approval is one transaction: the status, the permission's
  # payroll effect and the audit commit together or not at all.
  describe "standard approval atomicity (a real permission payroll effect)" do
    around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

    let(:employee)  { create(:user, business: business) }
    let(:branch)    { create(:branch, business: business) }
    let(:shift)     { create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00")) }
    let(:work_date) { Date.new(2026, 6, 8) }
    let(:period)    { create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22, status: "under_review") }
    let(:entry)     { create(:payroll_entry, payroll_period: period, user: employee, base_salary: 8_800, net_salary: 8_500, needs_review: false) }
    let!(:line) do
      assignment = create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
      create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1))
      create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                            deduction_type: "percentage_of_daily", deduction_value: 25)
      attendance = create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                                              date: work_date, work_date: work_date, late_minutes: 40, status: "late",
                                              check_in_at: Time.zone.local(2026, 6, 8, 9, 40))
      create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved",
                                 source_type: "AttendanceRecord", source_id: attendance.id,
                                 original_minutes: 40, permission_minutes: 0)
    end
    let!(:request) do
      build(:employee_request, :late_permission, user: employee, requested_for_date: work_date, duration_minutes: 20)
        .tap { |req| req.save!(validate: false) }
    end

    it "applies the effect with the approval (control)" do
      expect(described_class.approve(request: request, reviewed_by: manager)).to be_success
      expect(line.reload.permission_minutes).to eq(20) # 40 − 20 = 20 min still penalised
      expect(request.reload.status).to eq("approved")
    end

    it "rolls the status and the applied effect back when the approval fails after the effect" do
      allow(Payroll::PermissionApplier).to receive(:call).and_wrap_original do |original, req|
        original.call(req)
        raise ActiveRecord::RecordInvalid, line.reload # after the line item was rewritten
      end

      result = described_class.approve(request: request, reviewed_by: manager)

      expect(result).not_to be_success
      expect(request.reload).to have_attributes(status: "pending", reviewed_by_id: nil, reviewed_at: nil)
      expect(line.reload).to have_attributes(amount: -100.0, permission_minutes: 0)
      expect(AuditLog.where(auditable: request, action: "approve")).to be_empty
    end
  end
end
