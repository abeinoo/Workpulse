require "rails_helper"

RSpec.describe "Finance::DailyReconciliations timeline — Handover Adjustment badges", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, :owner, business: business) }
  let(:sender)   { create(:user, business: business) }
  let(:receiver) { create(:user, business: business) }

  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:visa_pm) { PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "open",
      opened_at: 1.hour.ago, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, current_holder: receiver) }

  let!(:handover) do
    TillHandover.create!(daily_reconciliation: dr, from_user: sender, to_user: receiver,
                          self_deposit: false, accepted_at: 1.hour.ago, fresha_date: dr.business_date)
  end

  before do
    TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 370, refund_amount: 0, kind: "operational")
    TillHandoverAmount.create!(till_handover: handover, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 5_956, refund_amount: 0, kind: "operational")
  end

  it "shows a badge with the adjusted (after) amount for each payment method named in the adjustment" do
    FinancialAdjustment.create!(
      adjustable: handover, business: business, actor: actor, reason_code: "wrong_amounts",
      notes: "Recount found a discrepancy at handover time",
      before_data: [ { payment_method_id: cash_pm.id, collected_amount: "370", refund_amount: "0" } ],
      after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ]
    )

    sign_in actor
    get finance_daily_reconciliation_path(dr)

    badges = adjustment_badges(response.body)
    expect(badges).to include("Cash")
    expect(badges).to include("470.00")
    expect(badges).not_to include("370.00")
  end

  it "shows only the payment methods that were actually adjusted, not every method on the handover" do
    FinancialAdjustment.create!(
      adjustable: handover, business: business, actor: actor, reason_code: "wrong_amounts",
      notes: "Recount found a discrepancy at handover time",
      before_data: [ { payment_method_id: cash_pm.id, collected_amount: "370", refund_amount: "0" } ],
      after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ]
    )

    sign_in actor
    get finance_daily_reconciliation_path(dr)

    # Visa legitimately appears elsewhere on the page (the Till Handover event's own
    # badges, showing the handover's raw amounts) — scope the assertion to just the
    # Handover Adjustment Recorded event's badge row so it isn't a false pass.
    badges = adjustment_badges(response.body)
    expect(badges).to include("Cash")
    expect(badges).not_to include("Visa")
  end

  # Finds the <p> story sentence for the handover_adjusted event ("... recorded an
  # adjustment on handover #...") and returns the text of the badge row rendered
  # immediately after it — scoping assertions to that one event instead of the
  # whole page, since other events on the same page legitimately show the same
  # payment method names/raw amounts.
  def adjustment_badges(body)
    doc    = Nokogiri::HTML(body)
    header = doc.at_xpath("//p[contains(., 'recorded an adjustment on handover #')]")
    header.next_element.css("span").map(&:text).join(" ")
  end
end
