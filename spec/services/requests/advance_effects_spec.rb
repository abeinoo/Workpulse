require "rails_helper"

# Batch A — Advance boundary: the Workforce contract Requests::AdvanceEffects and
# its Attendance & Payroll implementation Payroll::AdvanceEffects (the
# Advance.create! that Requests::Approver#pay used to make). Behaviour stays
# pinned by spec/characterization/workforce/advance_payment_spec.rb and the F-A1
# locking by spec/services/requests/advance_payment_lock_spec.rb.
RSpec.describe Requests::AdvanceEffects do
  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:employee)   { create(:user, business: business) }
  let!(:request)   { create(:employee_request, :salary_advance, :approved, amount: 800, user: employee) }
  let(:paid_at)    { Time.zone.local(2026, 10, 14, 9, 0) }

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
      expect(described_class.handler).to equal(Payroll::AdvanceEffects)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      expect { described_class.register(Module.new) }.to raise_error(ArgumentError, /advance_paid/)
      expect(described_class.handler).to equal(Payroll::AdvanceEffects)
    end

    it "raises NotRegistered instead of paying without an advance" do
      with_handler(nil) do
        expect { described_class.advance_paid(request: request, paid_at: paid_at) }.to raise_error(described_class::NotRegistered)
      end
    end
  end

  describe "dispatch" do
    it "passes the request and time to the handler and returns nil" do
      handler = double("handler", advance_paid: :ignored)

      with_handler(handler) { expect(described_class.advance_paid(request: request, paid_at: paid_at)).to be_nil }
      expect(handler).to have_received(:advance_paid).with(request: request, paid_at: paid_at)
    end

    it "propagates a handler error" do
      handler = double("handler")
      allow(handler).to receive(:advance_paid).and_raise(ActiveRecord::RecordInvalid.new(Advance.new))

      with_handler(handler) do
        expect { described_class.advance_paid(request: request, paid_at: paid_at) }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe "Payroll::AdvanceEffects" do
    it "records the Advance for the full request amount, issued at the payment time" do
      expect { described_class.advance_paid(request: request, paid_at: paid_at) }.to change(Advance, :count).by(1)

      expect(Advance.find_by!(employee_request_id: request.id))
        .to have_attributes(user_id: employee.id, total_amount: 800, remaining_amount: 800, status: "active", issued_at: paid_at)
    end
  end

  describe "routing (Requests::Approver#pay)" do
    it "records the advance through the contract, once, with the request and the payment time, in the pay transaction" do
      allow(described_class).to receive(:advance_paid).and_call_original

      Requests::Approver.pay(request: request, paid_by: accountant, paid_at: paid_at)

      expect(described_class).to have_received(:advance_paid).once.with(request: request, paid_at: paid_at)
      expect(request.reload.status).to eq("paid")
    end

    it "does not reach the contract when payment is refused" do
      pending_request = create(:employee_request, :salary_advance, :pending, user: employee)
      allow(described_class).to receive(:advance_paid)

      Requests::Approver.pay(request: pending_request, paid_by: accountant)

      expect(described_class).not_to have_received(:advance_paid)
    end

    it "rolls the paid status back when the handler fails" do
      handler = double("handler")
      allow(handler).to receive(:advance_paid).and_raise(ActiveRecord::RecordInvalid.new(Advance.new))

      result = with_handler(handler) { Requests::Approver.pay(request: request, paid_by: accountant) }

      expect(result).not_to be_success
      expect(request.reload.status).to eq("approved")
      expect(AuditLog.where(auditable: request, action: "pay")).to be_empty
    end
  end
end
