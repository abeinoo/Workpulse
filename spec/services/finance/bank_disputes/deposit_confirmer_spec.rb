require "rails_helper"

RSpec.describe Finance::BankDisputes::DepositConfirmer do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:employee)    { create(:user, business: business) }
  let(:accountant)  { create(:user, business: business) }
  let(:cash_pm)     { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current,
      reviewed_by: employee, reviewed_at: 1.minute.ago
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: employee.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 300, refund_amount: 0)
  end

  let(:dispute) do
    BankDispute.create!(daily_reconciliation: dr, business: business, branch: branch, opened_by: employee,
                        opened_at: Time.current, transaction_date: Date.current, transaction_time: "14:00",
                        kind: "atm_deposit_failure", status: "confirmed_successful",
                        amount: 300, bank_name: "NBE", terminal_id: "T-001", card_last4: "1234")
  end

  def confirm(**args)
    described_class.new(dispute.id, actor: accountant, payment_method_id: cash_pm.id, **args).call
  end

  it "creates the TillDeposit attributed to the original reporter and closes the dispute" do
    result = confirm

    expect(result.ok?).to be true
    expect(result.till_deposit).to be_persisted
    expect(result.till_deposit.deposited_by).to eq(employee)
    expect(result.till_deposit.amount).to eq(300)
    expect(dr.reload.total_deposited).to eq(300)
    expect(dispute.reload.status).to eq("closed")
    expect(dispute.till_deposit).to eq(result.till_deposit)
  end

  it "logs a distinct audit entry for the confirming accountant" do
    result = confirm

    log = AuditLog.where(auditable: dispute, action: "deposit_recorded_from_dispute").sole
    expect(log.actor).to eq(accountant)
    expect(log.metadata["till_deposit_id"]).to eq(result.till_deposit.id)
  end

  it "allows overriding the amount" do
    result = confirm(amount: 250)

    expect(result.ok?).to be true
    expect(result.till_deposit.amount).to eq(250)
  end

  it "rejects confirming a dispute that isn't confirmed_successful" do
    dispute.update!(status: "under_investigation")

    result = confirm

    expect(result.ok?).to be false
    expect(TillDeposit.count).to eq(0)
  end

  it "rejects confirming a dispute that already has a deposit" do
    other_deposit = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: employee,
                                        amount: 300, deposited_at: Time.current)
    dispute.update!(till_deposit: other_deposit)

    result = confirm

    expect(result.ok?).to be false
  end

  it "rolls back everything when the underlying deposit recorder rejects it" do
    dr.update_columns(reviewed_at: nil, reviewed_by_id: nil)

    result = confirm

    expect(result.ok?).to be false
    expect(TillDeposit.count).to eq(0)
    expect(dispute.reload.status).to eq("confirmed_successful")
    expect(AuditLog.where(auditable: dispute, action: "deposit_recorded_from_dispute")).to be_empty
  end
end
