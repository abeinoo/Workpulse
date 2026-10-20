require "rails_helper"

# F-A1 — paying and cancelling a salary advance lock the request row and
# re-check the committed state (Requests::Approver#pay, Requests::Canceller).
# Before the fix, pay checked a possibly stale copy without a lock, so a
# cancellation committed in between was overwritten (the request ended "paid"
# with an Advance deducted by payroll); and a cancellation never locked an
# advance, so it could overwrite a committed payment the same way.
#
# Two kinds of example:
# * stale copy — the competing operation really commits first, then the stale
#   copy is used: the end state (still cancelled / still paid) is asserted;
# * lock injection — on a freshly loaded request, the competing change is
#   written at the moment the row lock is requested (wrapping lock!), so the
#   re-check under the lock is exercised without a stale in-memory object. In
#   the transactional test that change sits inside the savepoint the refused
#   operation rolls back, so these examples assert the refusal and the absence
#   of the refused operation's effects, not the competing change's persistence.
#
# Limitation: every example runs on ONE database connection inside the test
# transaction. None is a true two-connection concurrency test; that the second
# of two concurrent transactions waits for the row lock and then reads the
# committed state is PostgreSQL's SELECT … FOR UPDATE semantics, not something
# these specs observe.
RSpec.describe "Salary advance payment / cancellation locking (F-A1)" do
  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:manager)    { create(:user, :branch_manager, business: business) }
  let(:employee)   { create(:user, business: business) }
  let!(:request) do
    create(:employee_request, :salary_advance, :approved, amount: 1_500.0, user: employee)
  end

  def pay_audits    = AuditLog.where(auditable: request, action: "pay")
  def cancel_audits = AuditLog.where(auditable: request, action: "cancel")

  # Writes `change` on the request's row (same connection) right before `record`
  # takes its lock; the real lock! still runs.
  def commit_before_lock(record, &change)
    allow(record).to receive(:lock!).and_wrap_original do |original, *args|
      change.call
      original.call(*args)
    end
  end

  def commit_cancellation = EmployeeRequest.where(id: request.id).update_all(status: "cancelled", cancelled_at: Time.current)

  def commit_payment
    EmployeeRequest.where(id: request.id).update_all(status: "paid", reviewed_at: Time.current)
    Advance.create!(user: employee, employee_request_id: request.id, total_amount: 1_500, remaining_amount: 1_500,
                    status: "active", issued_at: Time.current)
  end

  describe "Requests::Approver.pay" do
    it "refuses a request cancelled after this copy was loaded (stale copy): no Advance, no pay audit" do
      stale = EmployeeRequest.find(request.id)
      expect(Requests::Canceller.cancel(request: EmployeeRequest.find(request.id), cancelled_by: manager,
                                        reason: "Not needed")).to be_success

      result = nil
      expect { result = Requests::Approver.pay(request: stale, paid_by: accountant) }.not_to change(Advance, :count)

      expect(result).not_to be_success
      expect(result.error).to eq(Requests::Approver::NOT_PAYABLE)
      expect(request.reload.status).to eq("cancelled")
      expect(pay_audits).to be_empty
    end

    it "re-checks under the row lock: a cancellation written just before the lock is taken wins" do
      fresh = EmployeeRequest.find(request.id)
      commit_before_lock(fresh) { commit_cancellation }

      result = nil
      expect { result = Requests::Approver.pay(request: fresh, paid_by: accountant) }.not_to change(Advance, :count)

      expect(fresh).to have_received(:lock!)
      expect(result).not_to be_success
      expect(result.error).to eq(Requests::Approver::NOT_PAYABLE)
      expect(request.reload.status).not_to eq("paid")
      expect(pay_audits).to be_empty
    end

    it "re-checks under the row lock: a payment written just before the lock is taken is not repeated (refused, no RecordNotUnique)" do
      fresh = EmployeeRequest.find(request.id)
      commit_before_lock(fresh) { commit_payment }

      result = nil
      expect { result = Requests::Approver.pay(request: fresh, paid_by: accountant) }.not_to raise_error

      expect(result).not_to be_success
      expect(result.error).to eq(Requests::Approver::NOT_PAYABLE)
      expect(pay_audits).to be_empty
    end

    it "still pays an approved advance: takes the lock, one Advance for the full amount, one pay audit with its metadata" do
      allow(request).to receive(:lock!).and_call_original
      paid_at = Time.zone.parse("2026-10-15 10:00")

      result = Requests::Approver.pay(request: request, paid_by: accountant, paid_at: paid_at, note: "Bank transfer")

      expect(result).to be_success
      expect(request).to have_received(:lock!)
      request.reload
      expect(request.status).to eq("paid")
      expect(request.reviewed_by).to eq(accountant)
      expect(request.response_note).to eq("Bank transfer")
      expect(request.advance).to have_attributes(total_amount: 1_500, remaining_amount: 1_500, status: "active",
                                                 issued_at: paid_at, user_id: employee.id)
      expect(pay_audits.count).to eq(1)
      expect(pay_audits.first.metadata).to include("amount" => "1500.0", "note" => "Bank transfer")
    end
  end

  describe "Requests::Canceller.cancel (salary advance)" do
    it "refuses to cancel a request paid after this copy was loaded (stale copy): the payment and its Advance stand" do
      stale = EmployeeRequest.find(request.id)
      expect(Requests::Approver.pay(request: EmployeeRequest.find(request.id), paid_by: accountant)).to be_success

      result = Requests::Canceller.cancel(request: stale, cancelled_by: manager, reason: "Too late")

      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("requests.errors.cannot_cancel_paid"))
      expect(request.reload.status).to eq("paid")
      expect(request.advance).to be_active
      expect(cancel_audits).to be_empty
    end

    it "re-checks under the row lock: a payment written just before the lock is taken wins" do
      fresh = EmployeeRequest.find(request.id)
      commit_before_lock(fresh) { commit_payment }

      result = Requests::Canceller.cancel(request: fresh, cancelled_by: manager, reason: "Too late")

      expect(fresh).to have_received(:lock!)
      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("requests.errors.cannot_cancel_paid"))
      expect(request.reload.status).not_to eq("cancelled")
      expect(cancel_audits).to be_empty
    end

    it "still cancels an approved, unpaid advance (no Advance created)" do
      result = nil
      expect { result = Requests::Canceller.cancel(request: request, cancelled_by: manager, reason: "Not needed") }
        .not_to change(Advance, :count)

      expect(result).to be_success
      expect(request.reload.status).to eq("cancelled")
      expect(cancel_audits.count).to eq(1)
    end
  end

  describe "Requests::BulkPaymentService" do
    it "reports a request cancelled just before its lock is taken as skipped and pays the rest" do
      other = create(:employee_request, :salary_advance, :approved, amount: 500.0,
                                                                   user: create(:user, business: business))
      fresh = EmployeeRequest.find(request.id)
      commit_before_lock(fresh) { commit_cancellation }

      result = Requests::BulkPaymentService.call(requests: [ fresh, other ], paid_by: accountant)

      expect(result.paid).to eq([ other ])
      expect(result.skipped.map { |s| [ s.request.id, s.reason ] }).to eq([ [ request.id, Requests::Approver::NOT_PAYABLE ] ])
      expect(Advance.where(employee_request_id: request.id)).to be_empty
      expect(other.reload.advance).to be_present
    end
  end
end
