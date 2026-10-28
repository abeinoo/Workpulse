require "rails_helper"

RSpec.describe Finance::DepositResponsibilityTransferRejecter, type: :model do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:from_user) { create(:user, business: business) }
  let(:to_user)   { create(:user, business: business) }
  let(:manager)   { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor: from_user) }
  let!(:transfer) do
    DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: from_user, to_user: to_user,
                                          initiated_by: manager)
  end

  def reject(actor: to_user, reason: "I'm off tomorrow")
    described_class.new(transfer.id, actor: actor, reason: reason).call
  end

  def err(key, **opts) = I18n.t("deposit_responsibility_transfers.errors.#{key}", **opts)

  it "rejects with a reason, keeps the old depositor, and records the audit entry" do
    result = reject

    expect(result).to be_ok
    transfer.reload
    expect(transfer).to be_rejected
    expect(transfer).not_to be_pending
    expect(transfer.rejected_by).to eq(to_user)
    expect(transfer.rejection_reason).to eq("I'm off tomorrow")
    expect(till_session.reload.depositor).to eq(from_user)

    log = AuditLog.where(auditable: transfer, action: "reject").sole
    expect(log.actor).to eq(to_user)
    expect(log.metadata["reason"]).to eq("I'm off tomorrow")
  end

  it "rolls the rejection back when its audit entry cannot be written (BUG-003, fail-closed)" do
    fail_audit_writes!(:reject)

    result = reject

    expect(result).not_to be_ok
    expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.deposit_transfer_audit_failed"))
    expect(transfer.reload).to be_pending
    expect(AuditLog.where(auditable: transfer, action: "reject")).to be_empty
  end

  it "frees the DR for a new transfer request" do
    reject
    expect { DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: from_user, to_user: manager) }
      .not_to raise_error
  end

  it "refuses anyone but the recipient — including the sender, a manager and the owner" do
    owner = create(:user, :owner, business: business)
    [ from_user, manager, owner ].each do |actor|
      expect(reject(actor: actor).error).to eq(err(:wrong_recipient))
    end
    expect(transfer.reload).to be_pending
  end

  it "requires a reason" do
    expect(reject(reason: "   ").error).to eq(err(:rejection_reason_blank))
    expect(transfer.reload).to be_pending
  end

  it "refuses a transfer that is no longer pending" do
    transfer.update!(accepted_at: Time.current, accepted_by: to_user)
    expect(reject.error).to eq(err(:not_pending))
  end

  it "wins or loses cleanly against an accept on the same transfer" do
    expect(Finance::DepositResponsibilityTransferAcceptor.new(transfer.id, actor: to_user).call).to be_ok
    expect(reject.error).to eq(err(:not_pending))
    expect(till_session.reload.depositor).to eq(to_user)
  end
end
