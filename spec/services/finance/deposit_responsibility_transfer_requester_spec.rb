require "rails_helper"

RSpec.describe Finance::DepositResponsibilityTransferRequester, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms, **attrs)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business, **attrs).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def cashier(**attrs) = user_with("close_till_session", "create_till_deposit", **attrs)

  let(:manager) { user_with("view_daily_reconciliation", "verify_daily_reconciliation") }
  let(:ahmed)   { cashier(first_name: "Ahmed",   last_name: "Bahaa") }
  let(:mohamed) { cashier(first_name: "Mohamed", last_name: "Ahmed") }
  let(:mahmoud) { cashier(first_name: "Mahmoud", last_name: "Saeed") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 2.hours.ago, closed_at: 1.hour.ago, business_date: Date.current
    )
  end
  let!(:session) { TillSession.create!(daily_reconciliation: dr, depositor: ahmed, closed_by: ahmed) }
  let!(:amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 1_000, refund_amount: 50)
  end

  def request_transfer(to:, actor: manager, **opts)
    described_class.new(dr.id, actor: actor, to_user_id: to.id, **opts).call
  end

  def err(key, **opts) = I18n.t("finance.daily_reconciliations.errors.#{key}", **opts)

  describe "requesting" do
    it "creates a pending transfer from the current depositor and leaves the depositor unchanged" do
      result = request_transfer(to: mohamed, notes: "Ahmed on leave", expected_depositor_id: ahmed.id)

      expect(result).to be_ok
      transfer = result.transfer
      expect(transfer).to be_pending
      expect(transfer.from_user).to eq(ahmed)
      expect(transfer.to_user).to eq(mohamed)
      expect(transfer.initiated_by).to eq(manager)
      expect(transfer.requester).to eq(manager)
      expect(transfer.notes).to eq("Ahmed on leave")
      expect(session.reload.depositor).to eq(ahmed)
    end

    it "records the request in the audit log" do
      transfer = request_transfer(to: mohamed, notes: "cover").transfer
      log = AuditLog.where(auditable: transfer, action: "request").sole
      expect(log.actor).to eq(manager)
      expect(log.metadata).to include("from_user_id" => ahmed.id, "to_user_id" => mohamed.id, "notes" => "cover")
    end

    it "changes no money, deposit, handover, POS or DR data" do
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, amount: 300,
                          deposited_by: ahmed, deposited_at: Time.current)
      dr.update!(state: "deposited")
      create(:pos_transaction, business: business, branch: branch, amount: 250)

      snapshot = lambda do
        [
          dr.reload.attributes.slice("state", "business_date", "closed_at", "verified_at", "reviewed_at"),
          session.reload.attributes.slice("depositor_id", "closed_by_id", "current_holder_id"),
          TillSessionAmount.where(daily_reconciliation: dr).pluck(:collected_amount, :refund_amount, :updated_at),
          TillDeposit.where(daily_reconciliation: dr).pluck(:amount, :deposited_by_id, :updated_at),
          TillHandover.where(daily_reconciliation: dr).pluck(:id, :updated_at),
          PosTransaction.where(business: business).pluck(:amount, :status, :updated_at),
          [ dr.expected_cash_deposit, dr.total_deposited, dr.pending_deposit_amount ]
        ]
      end

      before = snapshot.call
      expect(request_transfer(to: mohamed)).to be_ok
      expect(snapshot.call).to eq(before)
    end
  end

  describe "guards" do
    it "refuses a second transfer while one is pending" do
      expect(request_transfer(to: mohamed)).to be_ok
      result = request_transfer(to: mahmoud)
      expect(result.error).to eq(err(:deposit_transfer_already_pending))
      expect(dr.deposit_responsibility_transfers.count).to eq(1)
    end

    it "allows a new transfer once the pending one was rejected" do
      first = request_transfer(to: mohamed).transfer
      first.update!(rejected_at: Time.current, rejected_by: mohamed, rejection_reason: "busy")
      expect(request_transfer(to: mahmoud)).to be_ok
    end

    it "refuses the current depositor, the requester themself, inactive and ineligible employees" do
      expect(request_transfer(to: ahmed).error).to eq(err(:deposit_transfer_same_depositor, name: "Ahmed Bahaa"))
      expect(request_transfer(to: manager).error).to eq(err(:deposit_transfer_self))

      mohamed.update!(active: false)
      expect(request_transfer(to: mohamed).error).to eq(err(:deposit_transfer_ineligible, name: "Mohamed Ahmed"))
      expect(request_transfer(to: user_with("view_daily_reconciliation"))).not_to be_ok
      expect(request_transfer(to: create(:user)).error).to eq(err(:invalid_depositor))
      expect(DepositResponsibilityTransfer.count).to eq(0)
    end

    it "refuses a verified or fully deposited day" do
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, amount: 950,
                          deposited_by: ahmed, deposited_at: Time.current)
      dr.update!(state: "deposited")
      expect(request_transfer(to: mohamed).error).to eq(err(:deposit_transfer_not_allowed))

      dr.update!(state: "verified", verified_at: Time.current)
      expect(request_transfer(to: mohamed).error).to eq(err(:deposit_transfer_not_allowed))
    end

    it "refuses a stale form whose depositor has since changed" do
      session.update!(depositor: mahmoud)
      expect(request_transfer(to: mohamed, expected_depositor_id: ahmed.id).error)
        .to eq(err(:deposit_transfer_stale, name: "Mahmoud Saeed"))
    end

    it "rolls back if the audit entry cannot be written" do
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
      expect(request_transfer(to: mohamed).error).to eq(err(:deposit_transfer_audit_failed))
      expect(DepositResponsibilityTransfer.count).to eq(0)
    end

    it "rolls back on a real database failure of the audit insert (BUG-003)" do
      fail_audit_writes!(:request)
      expect(request_transfer(to: mohamed).error).to eq(err(:deposit_transfer_audit_failed))
      expect(DepositResponsibilityTransfer.count).to eq(0)
    end
  end
end
