require "rails_helper"

RSpec.describe Requests::BulkPaymentService do
  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }

  def approved_advance(amount: 1_000.0)
    create(:employee_request, :salary_advance, :approved, amount: amount,
           user: create(:user, business: business))
  end

  describe ".call — full success" do
    let!(:r1) { approved_advance(amount: 1_000.0) }
    let!(:r2) { approved_advance(amount: 2_500.0) }

    it "marks every selected advance as paid" do
      described_class.call(requests: [r1, r2], paid_by: accountant)
      expect(r1.reload).to be_paid
      expect(r2.reload).to be_paid
    end

    it "creates one Advance per request" do
      expect {
        described_class.call(requests: [r1, r2], paid_by: accountant)
      }.to change(Advance, :count).by(2)
    end

    it "returns the paid count and total amount" do
      result = described_class.call(requests: [r1, r2], paid_by: accountant)
      expect(result.paid_count).to eq(2)
      expect(result.skipped_count).to eq(0)
      expect(result.total_amount).to eq(3_500.0)
      expect(result).to be_any_paid
    end

    it "stamps the Advance with the supplied payment date" do
      paid_on = "2026-06-01"
      described_class.call(requests: [r1], paid_by: accountant, paid_at: paid_on)
      expect(r1.advance.issued_at.to_date).to eq(Date.parse(paid_on))
    end

    it "defaults the payment date to now when none is supplied" do
      freeze_time do
        described_class.call(requests: [r1], paid_by: accountant)
        expect(r1.advance.issued_at).to be_within(1.second).of(Time.current)
      end
    end

    it "stores the optional note on each request" do
      described_class.call(requests: [r1], paid_by: accountant, notes: "Bank transfer")
      expect(r1.reload.response_note).to eq("Bank transfer")
    end

    it "writes a single bulk AuditLog summarising the batch" do
      expect {
        described_class.call(requests: [r1, r2], paid_by: accountant, paid_at: "2026-06-01")
      }.to change { AuditLog.where(action: "bulk_pay_advances").count }.by(1)

      log = AuditLog.where(action: "bulk_pay_advances").last
      expect(log.actor).to eq(accountant)
      expect(log.business).to eq(business)
      expect(log.metadata["request_count"]).to eq(2)
      expect(log.metadata["total_amount"]).to eq(3_500.0)
      expect(log.metadata["request_ids"]).to match_array([r1.id, r2.id])
      expect(log.metadata["paid_at"]).to be_present
    end

    it "still writes per-request pay audit logs" do
      expect {
        described_class.call(requests: [r1, r2], paid_by: accountant)
      }.to change { AuditLog.where(action: "pay").count }.by(2)
    end
  end

  describe ".call — partial failure" do
    let!(:payable)      { approved_advance(amount: 1_000.0) }
    let!(:pending)      { create(:employee_request, :salary_advance, amount: 500.0, user: create(:user, business: business)) }
    let!(:rejected)     { create(:employee_request, :salary_advance, :rejected, amount: 500.0, user: create(:user, business: business)) }
    let!(:non_advance)  { create(:employee_request, :early_leave, :approved, user: create(:user, business: business)) }
    let!(:already_paid) do
      req = approved_advance(amount: 700.0)
      Requests::Approver.pay(request: req, paid_by: accountant)
      req
    end

    it "pays only the valid advances" do
      described_class.call(
        requests: [payable, pending, rejected, non_advance, already_paid],
        paid_by:  accountant
      )
      expect(payable.reload).to be_paid
      expect(pending.reload).to be_pending
      expect(rejected.reload).to be_rejected
    end

    it "reports the skipped requests with reasons" do
      result = described_class.call(
        requests: [payable, pending, rejected, non_advance, already_paid],
        paid_by:  accountant
      )

      expect(result.paid_count).to eq(1)
      expect(result.skipped_count).to eq(4)

      reasons = result.skipped.each_with_object({}) { |s, h| h[s.request] = s.reason }
      expect(reasons[pending]).to eq(:not_approved)
      expect(reasons[rejected]).to eq(:rejected)
      expect(reasons[non_advance]).to eq(:not_advance)
      expect(reasons[already_paid]).to eq(:already_paid)
    end

    it "only counts the valid advance in the total and audit log" do
      result = described_class.call(
        requests: [payable, pending, rejected],
        paid_by:  accountant
      )
      expect(result.total_amount).to eq(1_000.0)
      log = AuditLog.where(action: "bulk_pay_advances").last
      expect(log.metadata["request_count"]).to eq(1)
    end
  end

  # F-A7: one lock order for every batch — the genuine two-connection proof is in
  # spec/services/requests/advance_payment_concurrency_spec.rb.
  describe ".call — lock order" do
    let!(:r1)      { approved_advance(amount: 1_000.0) }
    let!(:r2)      { approved_advance(amount: 2_000.0) }
    let!(:pending) { create(:employee_request, :salary_advance, amount: 500.0, user: create(:user, business: business)) }
    let!(:r3)      { approved_advance(amount: 3_000.0) }

    it "pays a reversed selection in ascending id order, skipped reasons unchanged" do
      result = described_class.call(requests: [ r3, pending, r2, r1 ], paid_by: accountant)

      expect(result.paid).to eq([ r1, r2, r3 ])
      expect(AuditLog.where(action: "pay").order(:id).pluck(:auditable_id)).to eq([ r1.id, r2.id, r3.id ]) # processing order
      expect(AuditLog.find_by!(action: "bulk_pay_advances").metadata["request_ids"]).to eq([ r1.id, r2.id, r3.id ])
      expect(result.skipped.map { |s| [ s.request, s.reason ] }).to eq([ [ pending, :not_approved ] ])
      expect(result.total_amount).to eq(6_000.0)
    end
  end

  describe ".call — nothing payable" do
    let!(:pending) { create(:employee_request, :salary_advance, amount: 500.0, user: create(:user, business: business)) }

    it "creates no advances and no bulk audit log" do
      expect {
        described_class.call(requests: [pending], paid_by: accountant)
      }.to change(Advance, :count).by(0)
      expect(AuditLog.where(action: "bulk_pay_advances")).to be_empty
    end

    it "reports the request as skipped" do
      result = described_class.call(requests: [pending], paid_by: accountant)
      expect(result).not_to be_any_paid
      expect(result.skipped_count).to eq(1)
    end
  end
end
