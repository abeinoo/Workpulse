require "rails_helper"

RSpec.describe DailyReconciliation, "#lifecycle_stage" do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:depositor) { create(:user, business: business) }

  def make_dr(state:, reviewed: false, verified: false)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: state,
      opened_at: 1.hour.ago, closed_at: (Time.current if state != "open" && state != "waiting_for_opening"),
      business_date: Date.current,
      reviewed_by: (depositor if reviewed), reviewed_at: (1.minute.ago if reviewed),
      verified_by: (depositor if verified), verified_at: (1.minute.ago if verified)
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: depositor.id) if state != "waiting_for_opening"
    dr
  end

  def deposit!(dr, amount:)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: depositor,
                        amount: amount, deposited_at: Time.current)
  end

  it "returns :awaiting_opening while waiting_for_opening?" do
    dr = make_dr(state: "waiting_for_opening")
    expect(dr.lifecycle_stage).to eq(:awaiting_opening)
    expect(dr.lifecycle_stage_index).to eq(0)
  end

  it "returns :open while the till session is open" do
    dr = make_dr(state: "open")
    expect(dr.lifecycle_stage).to eq(:open)
    expect(dr.lifecycle_stage_index).to eq(1)
  end

  it "returns :awaiting_deposit once closed, before any deposit exists" do
    dr = make_dr(state: "closed")
    expect(dr.lifecycle_stage).to eq(:awaiting_deposit)
    expect(dr.lifecycle_stage_index).to eq(2)
  end

  it "returns :awaiting_branch_review once deposited but not yet reviewed" do
    dr = make_dr(state: "deposited", reviewed: false)
    deposit!(dr, amount: 100)
    expect(dr.lifecycle_stage).to eq(:awaiting_branch_review)
    expect(dr.lifecycle_stage_index).to eq(3)
  end

  it "returns :awaiting_accounting_approval once reviewed but not yet verified" do
    dr = make_dr(state: "deposited", reviewed: true)
    deposit!(dr, amount: 100)
    expect(dr.lifecycle_stage).to eq(:awaiting_accounting_approval)
    expect(dr.lifecycle_stage_index).to eq(4)
  end

  it "returns :verified once verified" do
    dr = make_dr(state: "verified", reviewed: true, verified: true)
    deposit!(dr, amount: 100)
    expect(dr.lifecycle_stage).to eq(:verified)
    expect(dr.lifecycle_stage_index).to eq(5)
  end

  it "is completely unaffected by an open RemainingDepositBalance shortfall" do
    dr = make_dr(state: "deposited", reviewed: true)
    dep = deposit!(dr, amount: 60)
    RemainingDepositBalance.create!(
      daily_reconciliation: dr, till_deposit: dep, responsible_user: depositor, created_by: depositor,
      business: business, branch: branch, amount: 40, remaining_amount: 40, status: "open"
    )

    expect(dr.lifecycle_stage).to eq(:awaiting_accounting_approval)
  end
end
