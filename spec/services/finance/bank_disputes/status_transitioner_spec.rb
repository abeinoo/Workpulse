require "rails_helper"

RSpec.describe Finance::BankDisputes::StatusTransitioner do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 16),
      reviewed_by: actor, reviewed_at: 1.minute.ago
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  let(:deposit) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: 300, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
  end

  let(:dispute) do
    BankDispute.create!(till_deposit: deposit, business: business, branch: branch, opened_by: actor,
                        opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
                        amount: 300, bank_name: "NBE", terminal_id: "T-001")
  end

  def transition(target, params = {})
    described_class.new(dispute.id, actor: actor, target_status: target, params: params).call
  end

  it "moves from new to submitted_to_bank, persisting the bank_ticket_number" do
    result = transition("submitted_to_bank", bank_ticket_number: "TCK-1")

    expect(result.ok?).to be true
    expect(result.dispute.status).to eq("submitted_to_bank")
    expect(result.dispute.bank_ticket_number).to eq("TCK-1")
  end

  it "walks the full happy path to refunded then closed" do
    expect(transition("submitted_to_bank").ok?).to be true
    expect(transition("under_investigation").ok?).to be true
    result = transition("refunded", notes: "Bank confirmed refund")
    expect(result.ok?).to be true
    expect(result.dispute.status).to eq("refunded")

    result = transition("closed")
    expect(result.ok?).to be true
    expect(result.dispute.status).to eq("closed")
  end

  it "supports the rejected branch" do
    transition("submitted_to_bank")
    transition("under_investigation")
    result = transition("rejected", notes: "Bank found no error")

    expect(result.ok?).to be true
    expect(result.dispute.status).to eq("rejected")
  end

  it "rejects skipping a state (new -> under_investigation)" do
    result = transition("under_investigation")

    expect(result.ok?).to be false
    expect(dispute.reload.status).to eq("new")
  end

  it "rejects any transition once closed" do
    transition("submitted_to_bank")
    transition("under_investigation")
    transition("rejected")
    transition("closed")

    result = transition("under_investigation")
    expect(result.ok?).to be false
  end

  it "writes an audit log entry per transition" do
    transition("submitted_to_bank", bank_ticket_number: "TCK-1")

    log = AuditLog.for_auditable(dispute).order(:created_at).last
    expect(log.action).to eq("submitted_to_bank")
    expect(log.actor).to eq(actor)
    expect(log.metadata["bank_ticket_number"]).to eq("TCK-1")
  end
end
