require "rails_helper"

# Pilot 9 — Request Permission Payroll Effects, M3-A / M3-B: Requests::Approver
# and Requests::Canceller reach the permission's payroll effect only through the
# Workforce contract Requests::PermissionPayrollEffects (approval since M3-A;
# cancellation since M3-B, landed with M4, which moved the revert into Attendance
# & Payroll). The behaviour is unchanged and stays pinned by
# spec/characterization/workforce/request_permission_payroll_effects_spec.rb.
RSpec.describe "Request permission payroll effects → Requests::PermissionPayrollEffects routing" do
  let(:contract) { Requests::PermissionPayrollEffects }
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:reviewer) { create(:user, :owner, business: business) }

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = contract.instance_variable_get(:@handler)
    contract.instance_variable_set(:@handler, handler)
    yield
  ensure
    contract.instance_variable_set(:@handler, original)
  end

  def request_of(type, status = :pending)
    build(:employee_request, type, status, user: employee, requested_for_date: Date.current - 1)
      .tap { |req| req.save!(validate: false) }
  end

  def approve(req) = Requests::Approver.approve(request: req, reviewed_by: reviewer)

  def audits(req) = AuditLog.where(auditable: req).pluck(:action)

  describe "Requests::Approver#approve_standard → permission_approved" do
    %i[late_permission early_leave].each do |type|
      it "#{type}: calls the contract once with the same request, after the approval is saved and before the audit" do
        req  = request_of(type)
        seen = nil
        handler = Module.new do
          define_singleton_method(:permission_cancelled) { |request:| :reverted }
          define_singleton_method(:permission_approved) do |request:|
            seen = { request: request, status: request.reload.status,
                     audited: AuditLog.exists?(auditable: request, action: "approve") }
          end
        end
        allow(Payroll::PermissionApplier).to receive(:call)

        result = with_handler(handler) { approve(req) }

        expect(result).to be_success
        expect(seen).to eq(request: req, status: "approved", audited: false)
        expect(audits(req)).to eq([ "approve" ])
        expect(Payroll::PermissionApplier).not_to have_received(:call) # only through the contract
      end
    end

    it "the registered implementation still runs Payroll::PermissionApplier with the request (unchanged effect)" do
      req = request_of(:late_permission)
      allow(Payroll::PermissionApplier).to receive(:call)

      approve(req)

      expect(Payroll::PermissionApplier).to have_received(:call).once.with(req)
    end

    it "a contract error propagates as before: request already approved, no approve audit" do
      req     = request_of(:early_leave)
      handler = double("handler", permission_cancelled: :reverted)
      allow(handler).to receive(:permission_approved).and_raise(StandardError, "boom")

      with_handler(handler) { expect { approve(req) }.to raise_error(StandardError, "boom") }
      expect(req.reload.status).to eq("approved")
      expect(audits(req)).to be_empty
    end

    it "a salary advance approval goes through the same call (the implementation does nothing for it), as before" do
      handler = double("handler", permission_approved: nil, permission_cancelled: :reverted)
      req = request_of(:salary_advance)

      with_handler(handler) { approve(req) }
      expect(handler).to have_received(:permission_approved).once.with(request: req)
    end

    it "punch-correction approval (its own path) and any rejection never call the contract" do
      handler = double("handler", permission_approved: nil, permission_cancelled: :reverted)
      allow(Requests::PunchCorrectionAssessment).to receive(:for)
        .and_return(double(punch_order_invalid?: false, requires_confirmation?: false, effective_at: Time.current, audit_metadata: {}))
      allow(Requests::PunchCorrectionApplier).to receive(:call).and_return(double(success?: true, approval: nil))
      punch = request_of(:punch_correction)

      with_handler(handler) do
        expect(approve(punch)).to be_success
        Requests::Approver.reject(request: request_of(:late_permission), reviewed_by: reviewer)
      end
      expect(punch.reload.status).to eq("approved")
      expect(handler).not_to have_received(:permission_approved)
    end
  end

  describe "Requests::Canceller#cancel → permission_cancelled (M3-B)" do
    def cancel(req) = Requests::Canceller.cancel(request: req, cancelled_by: reviewer, reason: "routing")

    %i[late_permission early_leave].each do |type|
      it "#{type}: calls the contract once with the same request inside the cancel transaction, before the status change" do
        req  = request_of(type, :approved)
        seen = nil
        depth = ActiveRecord::Base.connection.open_transactions
        handler = Module.new do
          define_singleton_method(:permission_approved) { |request:| nil }
          define_singleton_method(:permission_cancelled) do |request:|
            seen = { request: request, status: request.reload.status,
                     in_transaction: ActiveRecord::Base.connection.open_transactions > depth }
            :reverted
          end
        end

        result = with_handler(handler) { cancel(req) }

        expect(result).to be_success
        expect(seen).to eq(request: req, status: "approved", in_transaction: true)
        expect(req.reload.status).to eq("cancelled")
        expect(audits(req)).to eq([ "cancel" ])
      end
    end

    it ":refused keeps the request approved with the cannot_cancel_finalized error and no cancel audit" do
      handler = double("handler", permission_approved: nil, permission_cancelled: :refused)
      req = request_of(:late_permission, :approved)

      result = with_handler(handler) { cancel(req) }

      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("requests.errors.cannot_cancel_finalized"))
      expect(req.reload.status).to eq("approved")
      expect(audits(req)).to be_empty
    end

    it "an invalid line item (RecordInvalid) gives the same failed result as before: messages, request approved, no audit" do
      handler = double("handler", permission_approved: nil)
      invalid = PayrollLineItem.new.tap { |li| li.errors.add(:amount, "is invalid") }
      allow(handler).to receive(:permission_cancelled).and_raise(ActiveRecord::RecordInvalid.new(invalid))
      req = request_of(:early_leave, :approved)

      result = with_handler(handler) { cancel(req) }

      expect(result).not_to be_success
      expect(result.error).to eq("Amount is invalid")
      expect(req.reload.status).to eq("approved")
      expect(audits(req)).to be_empty
    end

    it "an unexpected error propagates and the cancel transaction rolls back" do
      handler = double("handler", permission_approved: nil)
      allow(handler).to receive(:permission_cancelled).and_raise(StandardError, "boom")
      req = request_of(:late_permission, :approved)

      with_handler(handler) { expect { cancel(req) }.to raise_error(StandardError, "boom") }
      expect(req.reload.status).to eq("approved")
      expect(audits(req)).to be_empty
    end

    it "pending permissions, salary advances and punch corrections never call it" do
      handler = double("handler", permission_approved: nil, permission_cancelled: :reverted)
      allow(Requests::PunchCorrectionApplier).to receive(:call)

      with_handler(handler) do
        cancel(request_of(:late_permission, :pending))
        cancel(request_of(:salary_advance, :approved))
        cancel(request_of(:punch_correction, :pending))
      end
      expect(handler).not_to have_received(:permission_cancelled)
    end
  end
end
