require "rails_helper"

# Pilot 9 — Request Permission Payroll Effects, M3-A: Requests::Approver
# reaches the permission's payroll effect only through the Workforce contract
# Requests::PermissionPayrollEffects instead of naming Payroll::PermissionApplier.
# The behaviour is unchanged and stays pinned by
# spec/characterization/workforce/request_permission_payroll_effects_spec.rb.
#
# Cancellation is intentionally NOT routed yet (M3-B lands with M4): the
# canceller still runs rollback_permission itself and never calls the contract.
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
      allow(Requests::PunchCorrectionApplier).to receive(:call).and_return(double(success?: true, record: nil))
      punch = request_of(:punch_correction)

      with_handler(handler) do
        expect(approve(punch)).to be_success
        Requests::Approver.reject(request: request_of(:late_permission), reviewed_by: reviewer)
      end
      expect(punch.reload.status).to eq("approved")
      expect(handler).not_to have_received(:permission_approved)
    end
  end

  describe "Requests::Canceller — not routed in M3-A" do
    it "cancelling an approved permission does not call the contract (rollback_permission still runs in Workforce)" do
      handler = double("handler", permission_approved: nil, permission_cancelled: :reverted)
      req = request_of(:late_permission, :approved)

      result = with_handler(handler) { Requests::Canceller.cancel(request: req, cancelled_by: reviewer, reason: "routing") }

      expect(result).to be_success
      expect(handler).not_to have_received(:permission_cancelled)
    end
  end
end
