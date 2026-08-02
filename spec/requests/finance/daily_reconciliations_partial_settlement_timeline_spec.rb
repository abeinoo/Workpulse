require "rails_helper"

RSpec.describe "Finance::DailyReconciliations show — Partial Settlement timeline detail", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:depositor) { user_with("view_daily_reconciliation", "create_till_deposit", "close_till_session") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: depositor.id) }

  # Expected cash for the day is 12,280 — so an 11,700 deposit leaves a
  # 580 shortfall (creates the RemainingDepositBalance), then 300 and 200
  # deposits each auto-settle part of it via
  # Finance::TillDepositRecorder#reconcile_remaining_balance!, exactly
  # mirroring the real production sequence this feature was built to explain.
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: cash_pm.name,
                              collected_amount: 12_280, refund_amount: 0)
  end

  def deposit!(amount)
    Finance::TillDepositRecorder.new(
      dr.id, actor: depositor,
      params: { payment_method_id: cash_pm.id, amount: amount, deposited_at: Time.current }
    ).call
  end

  before do
    deposit!(11_700)
    deposit!(300)
    deposit!(200)
  end

  it "creates one RemainingDepositBalance auto-settled by the two later deposits" do
    rdb = dr.remaining_deposit_balances.sole
    expect(rdb.amount).to eq(580)
    expect(rdb.remaining_amount).to eq(80)
    expect(rdb.balance_transactions.pluck(:transaction_type, :amount)).to eq(
      [ [ "created", 580.0 ], [ "settlement", 300.0 ], [ "settlement", 200.0 ] ]
    )
  end

  it "labels each Partial Settlement event with the payment method that performed it" do
    sign_in depositor
    get finance_daily_reconciliation_path(dr)

    doc = Nokogiri::HTML(response.body)
    chips = doc.css("#audit-log span").select { |s| s.text.include?("Partial Settlement") }
    expect(chips.size).to eq(2)
    chips.each { |chip| expect(chip.text.squish).to eq("Partial Settlement (Cash)") }
  end

  it "shows Payment Method, Settlement Amount, Deposit Amount, and Remaining Difference for the first (300) settlement" do
    sign_in depositor
    get finance_daily_reconciliation_path(dr)

    doc = Nokogiri::HTML(response.body)
    settlement_details = doc.css("#audit-log [data-timeline-event-target='detail']")
                             .select { |d| d.text.include?("Remaining Balance #") && d.text.include?("Settled amount") }
    detail = settlement_details.find { |d| d.text.squish.include?("Remaining Difference 280.00") }
    text = detail.text.squish

    expect(text).to include("Payment Method Cash")
    expect(text).to include("Settled amount")
    expect(text).to include("Deposit Amount 300.00")
    expect(text).to include("Remaining Difference 280.00")
  end

  it "shows Deposit Amount and Remaining Difference for the second (200) settlement, reflecting the running balance" do
    sign_in depositor
    get finance_daily_reconciliation_path(dr)

    doc = Nokogiri::HTML(response.body)
    settlement_details = doc.css("#audit-log [data-timeline-event-target='detail']")
                             .select { |d| d.text.include?("Remaining Balance #") && d.text.include?("Settled amount") }
    detail = settlement_details.find { |d| d.text.squish.include?("Remaining Difference 80.00") }
    text = detail.text.squish

    expect(text).to include("Payment Method Cash")
    expect(text).to include("Deposit Amount 200.00")
    expect(text).to include("Remaining Difference 80.00")
  end

  it "does not label the balance-creation event (11,700 deposit) as Partial Settlement — exactly two settlement chips exist" do
    sign_in depositor
    get finance_daily_reconciliation_path(dr)

    doc = Nokogiri::HTML(response.body)
    audit_text = doc.at_css("#audit-log").text
    expect(audit_text).to include("Remaining Balance")
    expect(audit_text.scan("Partial Settlement").size).to eq(2)
  end
end
