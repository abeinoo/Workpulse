require "rails_helper"

# Pilot 9 — Request Permission Payroll Effects, M2: the Workforce contract
# Requests::PermissionPayrollEffects and its Attendance & Payroll implementation
# Payroll::PermissionPayrollEffects (approval → PermissionApplier; cancellation
# delegating to Requests::Canceller.revert_permission_payroll until M4).
# Requests::Approver and Requests::Canceller are routed through the contract in
# M3; the behaviour stays pinned by
# spec/characterization/workforce/request_permission_payroll_effects_spec.rb.
RSpec.describe Requests::PermissionPayrollEffects do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 22) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22, status: "under_review")
  end
  let(:work_date) { Date.new(2026, 6, 8) }
  let(:attendance) do
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment, date: work_date,
                               work_date: work_date, check_in_at: Time.zone.local(2026, 6, 8, 9, 40),
                               check_out_at: Time.zone.local(2026, 6, 8, 17, 0), worked_minutes: 440,
                               late_minutes: 40, early_leave_minutes: 0, status: "late")
  end
  let(:entry) { create(:payroll_entry, payroll_period: period, user: employee, base_salary: 8_800, net_salary: 8_700) }
  let!(:line) do
    create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved",
                               source_type: "AttendanceRecord", source_id: attendance.id, original_minutes: 40,
                               permission_minutes: 0)
  end

  before do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1))
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                          deduction_type: "percentage_of_daily", deduction_value: 25)
  end

  def permission(minutes = 40, status: :approved, date: work_date)
    build(:employee_request, :late_permission, status, user: employee, requested_for_date: date, duration_minutes: minutes)
      .tap { |req| req.save!(validate: false) }
  end

  def penalty_line = entry.payroll_line_items.find_by(item_type: "late_penalty", source_id: attendance.id)

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  describe "registration" do
    it "has the Attendance & Payroll implementation registered at boot" do
      expect(described_class.handler).to equal(Payroll::PermissionPayrollEffects)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      incomplete = Module.new { def self.permission_approved(request:) = nil }

      expect { described_class.register(incomplete) }.to raise_error(ArgumentError, /permission_cancelled/)
      expect(described_class.handler).to equal(Payroll::PermissionPayrollEffects)
    end

    it "raises NotRegistered (a StandardError) instead of silently skipping when no handler is registered" do
      expect(described_class::NotRegistered.ancestors).to include(StandardError)
      with_handler(nil) do
        expect { described_class.permission_approved(request: permission) }.to raise_error(described_class::NotRegistered)
        expect { described_class.permission_cancelled(request: permission) }.to raise_error(described_class::NotRegistered)
      end
    end
  end

  describe "dispatch" do
    let(:handler) { double("handler", permission_approved: :ignored, permission_cancelled: :reverted) }
    let(:request) { permission }

    it "permission_approved passes the request unchanged and returns nothing (no refusal exists for approval)" do
      with_handler(handler) { expect(described_class.permission_approved(request: request)).to be_nil }
      expect(handler).to have_received(:permission_approved).once.with(request: request)
    end

    it "permission_cancelled passes the request and returns :reverted or :refused" do
      %i[reverted refused].each do |answer|
        allow(handler).to receive(:permission_cancelled).and_return(answer)
        with_handler(handler) { expect(described_class.permission_cancelled(request: request)).to eq(answer) }
      end
      expect(handler).to have_received(:permission_cancelled).with(request: request).twice
    end

    it "permission_cancelled accepts only the two results — no payroll record, String, boolean or nil crosses the contract" do
      [ period, "reverted", true, nil ].each do |leak|
        allow(handler).to receive(:permission_cancelled).and_return(leak)
        with_handler(handler) do
          expect { described_class.permission_cancelled(request: request) }.to raise_error(ArgumentError, /expected one of/)
        end
      end
      expect(described_class::CANCEL_RESULTS).to eq(%i[reverted refused])
    end

    it "propagates an unexpected handler error from either operation" do
      allow(handler).to receive(:permission_approved).and_raise(StandardError, "boom")
      allow(handler).to receive(:permission_cancelled).and_raise(StandardError, "boom")

      with_handler(handler) do
        expect { described_class.permission_approved(request: request) }.to raise_error(StandardError, "boom")
        expect { described_class.permission_cancelled(request: request) }.to raise_error(StandardError, "boom")
      end
    end
  end

  describe "through the Attendance & Payroll implementation" do
    it "permission_approved is PermissionApplier: the open-period line is adjusted" do
      req = permission(40)
      allow(Payroll::PermissionApplier).to receive(:call).and_call_original

      described_class.permission_approved(request: req)

      expect(Payroll::PermissionApplier).to have_received(:call).once.with(req)
      expect(penalty_line).to be_nil # fully covered → removed, as PermissionApplier does
    end

    it "permission_approved is a no-op for a locked period or a non-permission request" do
      period.update_column(:status, "finalized")
      described_class.permission_approved(request: permission(40))
      advance = build(:employee_request, :salary_advance, :approved, user: employee, requested_for_date: work_date)
      advance.save!(validate: false)
      described_class.permission_approved(request: advance)

      expect(line.reload).to have_attributes(amount: -100.0, permission_minutes: 0)
    end

    it "permission_cancelled reverts an open-period effect → :reverted (the request itself is not cancelled or audited)" do
      req = permission(40)
      described_class.permission_approved(request: req)

      expect(described_class.permission_cancelled(request: req)).to eq(:reverted)
      expect(penalty_line).to have_attributes(amount: -100.0, original_minutes: 40)
      expect(req.reload.status).to eq("approved")
      expect(AuditLog.where(auditable: req)).to be_empty
    end

    %w[finalized paid].each do |status|
      it "permission_cancelled for a #{status} period → :refused, payroll untouched" do
        req = permission(40)
        described_class.permission_approved(request: req)
        period.update_column(:status, status)

        expect(described_class.permission_cancelled(request: req)).to eq(:refused)
        expect(penalty_line).to be_nil
      end
    end

    it "permission_cancelled with nothing to revert (no attendance record for the date) → :reverted" do
      expect(described_class.permission_cancelled(request: permission(40, date: work_date + 1))).to eq(:reverted)
      expect(line.reload.amount).to eq(-100.0)
    end

    it "any other revert failure raises (Requests::Canceller::PermissionRevertFailed with the messages)" do
      allow_any_instance_of(Requests::Canceller).to receive(:rollback_permission)
        .and_return(Requests::Canceller::Result.new(success: false, error: "Amount is invalid"))

      expect { described_class.permission_cancelled(request: permission(40)) }
        .to raise_error(Requests::Canceller::PermissionRevertFailed, "Amount is invalid")
    end
  end

  it "keeps the Workforce contract free of Attendance & Payroll references" do
    source = File.read(Rails.root.join("app/services/requests/permission_payroll_effects.rb"))
    code   = source.each_line.reject { |line| line.lstrip.start_with?("#") }.join

    expect(code).not_to match(/\bPayroll\b|\bAttendance::|\bSalary::|PermissionApplier|PayrollPeriod|PayrollEntry|PayrollLineItem|AttendanceRecord/)
  end
end
