require "rails_helper"

# Characterization (Batch A — Advance boundary, M1) — CURRENT salary-advance
# approval and payment (module-boundaries.md §14.2 #2): Requests::Approver#approve
# creates nothing financial; #pay turns the approved request "paid" and creates
# the Attendance & Payroll Advance in one transaction; BulkPaymentService pays a
# selection through #pay. Recorded against the code at fa81c7d (after the F-A1
# lock fix, whose race behaviour is pinned in
# spec/services/requests/advance_payment_lock_spec.rb). The former
# EmployeeRequestsController#mark_all_paid / Approver.pay_all (defect F-A3,
# next-pilot-selection.md §29) were removed; bulk payment is BulkPaymentService.
RSpec.describe "Characterization: salary advance approval and payment", type: :model do
  around { |ex| travel_to(Time.zone.local(2026, 10, 15, 12, 0, 0)) { ex.run } }

  let(:business)   { create(:business) }
  let(:manager)    { create(:user, :branch_manager, business: business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:employee)   { create(:user, business: business) }

  let(:refusal) { "Only approved salary advance requests can be marked as paid" }

  def advance_request(*traits, **attrs)
    create(:employee_request, :salary_advance, *traits, amount: 2_250.5, user: employee, **attrs)
  end

  def audits(request, action) = AuditLog.where(auditable: request, action: action)

  describe "approval" do
    it "approves without creating an Advance (one approve audit, no pay audit)" do
      request = advance_request(:pending)

      result = nil
      expect { result = Requests::Approver.approve(request: request, reviewed_by: manager, response_note: "OK") }
        .not_to change(Advance, :count)

      expect(result).to be_success
      request.reload
      expect(request).to have_attributes(status: "approved", reviewed_by_id: manager.id, response_note: "OK")
      expect(audits(request, "approve").count).to eq(1)
      expect(audits(request, "pay")).to be_empty
    end
  end

  describe "payment" do
    let!(:request) { advance_request(:approved, response_note: "Approved by manager") }

    it "pays with the given time and note: request paid, one Advance for the full amount, one pay audit" do
      paid_at = Time.zone.local(2026, 10, 14, 9, 30)

      result = Requests::Approver.pay(request: request, paid_by: accountant, paid_at: paid_at, note: "Bank transfer")

      expect(result).to be_success
      expect(result.request).to eq(request)
      request.reload
      expect(request).to have_attributes(status: "paid", reviewed_by_id: accountant.id, response_note: "Bank transfer")
      expect(request.reviewed_at).to eq(Time.current)

      advance = Advance.find_by!(employee_request_id: request.id)
      expect(advance).to have_attributes(user_id: employee.id, total_amount: BigDecimal("2250.5"),
                                         remaining_amount: BigDecimal("2250.5"), status: "active", issued_at: paid_at)

      audit = audits(request, "pay").sole
      expect(audit.actor).to eq(accountant)
      expect(audit.changes_json).to eq("status" => %w[approved paid])
      expect(audit.metadata).to eq("amount" => "2250.5", "paid_at" => paid_at.as_json, "note" => "Bank transfer")
    end

    it "defaults the payment time to now and keeps the approval note when no note is given (no note in the audit)" do
      Requests::Approver.pay(request: request, paid_by: accountant)

      request.reload
      expect(request.response_note).to eq("Approved by manager")
      expect(request.advance.issued_at).to eq(Time.current)
      expect(audits(request, "pay").sole.metadata).to eq("amount" => "2250.5", "paid_at" => Time.current.as_json)
    end

    it "is atomic: when the Advance cannot be saved the request stays approved, with no Advance and no pay audit" do
      invalid = Advance.new.tap { |a| a.errors.add(:base, "cannot record the advance") }
      allow(Advance).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid))

      result = Requests::Approver.pay(request: request, paid_by: accountant)

      expect(result).not_to be_success
      expect(result.error).to eq("cannot record the advance")
      expect(request.reload.status).to eq("approved")
      expect(Advance.where(employee_request_id: request.id)).to be_empty
      expect(audits(request, "pay")).to be_empty
    end
  end

  describe "payment refused (nothing written)" do
    {
      "a pending advance"   => -> { advance_request(:pending) },
      "a rejected advance"  => -> { advance_request(:rejected) },
      "a cancelled advance" => -> { advance_request(:approved).tap { |r| r.update_columns(status: "cancelled") } },
      "a paid advance"      => -> { advance_request(:approved).tap { |r| r.update_columns(status: "paid") } },
      "an approved non-advance request" => lambda {
        create(:employee_request, :late_permission, :approved, user: employee)
      }
    }.each do |label, build|
      it "refuses #{label}" do
        request = instance_exec(&build)
        status  = request.status

        result = nil
        expect { result = Requests::Approver.pay(request: request, paid_by: accountant) }.not_to change(Advance, :count)

        expect(result).not_to be_success
        expect(result.error).to eq(refusal)
        expect(request.reload.status).to eq(status)
        expect(audits(request, "pay")).to be_empty
      end
    end

    it "refuses an approved request that already has an Advance row (one Advance stays)" do
      request = advance_request(:approved)
      Advance.create!(user: employee, employee_request: request, total_amount: 1, remaining_amount: 1,
                      status: "active", issued_at: 1.day.ago)

      result = Requests::Approver.pay(request: EmployeeRequest.find(request.id), paid_by: accountant)

      expect(result.error).to eq(refusal)
      expect(Advance.where(employee_request_id: request.id).count).to eq(1)
      expect(request.reload.status).to eq("approved")
    end
  end

  describe "bulk payment (Requests::BulkPaymentService)" do
    it "pays the approved advances through #pay with the batch time and note, and reports the rest as skipped" do
      payable  = advance_request(:approved)
      other    = create(:employee_request, :salary_advance, :approved, amount: 100, user: create(:user, business: business))
      pending  = advance_request(:pending)
      rejected = advance_request(:rejected)

      result = Requests::BulkPaymentService.call(requests: [ payable, other, pending, rejected ], paid_by: accountant,
                                                 paid_at: "2026-10-14 08:00", notes: "October batch")

      expect(result.paid).to contain_exactly(payable, other)
      expect(result.skipped.map { |s| [ s.request.id, s.reason ] }).to contain_exactly([ pending.id, :not_approved ],
                                                                                       [ rejected.id, :rejected ])
      [ payable, other ].each do |request|
        request.reload
        expect(request).to have_attributes(status: "paid", response_note: "October batch")
        expect(request.advance).to have_attributes(total_amount: request.amount, remaining_amount: request.amount,
                                                   issued_at: Time.zone.parse("2026-10-14 08:00"))
        expect(audits(request, "pay").count).to eq(1)
      end
      expect(AuditLog.where(action: "bulk_pay_advances").count).to eq(1)
    end
  end
end
