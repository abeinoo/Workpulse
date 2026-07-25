require "rails_helper"

RSpec.describe "Finance::DailyReconciliations timeline — Deposit Review events", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:manager)  { create(:user, :owner, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: manager.id) }

  before { sign_in manager }

  def record_deposit!(amount: 100)
    TillSessionAmount.find_or_create_by!(daily_reconciliation: dr, payment_method: cash_pm) do |sa|
      sa.payment_method_name = cash_pm.name
      sa.collected_amount    = amount
      sa.refund_amount       = 0
    end
    dr.till_deposits.create!(payment_method: cash_pm, deposited_by: manager, amount: amount, deposited_at: Time.current)
    dr.update_columns(state: "deposited")
    dr.reload
  end

  it "shows Branch Review Completed after approving the recorded deposit" do
    record_deposit!
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call

    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Branch Review Completed")
  end

  it "shows Branch Review Cancelled after cancelling the approval" do
    record_deposit!
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call
    Finance::DailyReconciliationReviewCanceller.new(dr.id, actor: manager).call

    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Branch Review Cancelled")
  end

  it "shows Branch Review Automatically Cancelled after a Session Totals correction invalidates the approval" do
    handover = TillHandover.create!(daily_reconciliation: dr, from_user: manager, self_deposit: true,
                                     opening_float_declaration: false, fresha_date: dr.business_date)
    TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 370, refund_amount: 0, kind: "operational")
    record_deposit!
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call

    # DayCloseEditor can no longer fire once deposited? — SessionAmountsEditor
    # is the correction path that can still run after a deposit/approval
    # exists, so it's what triggers clear_review! under the new order.
    Finance::SessionAmountsEditor.new(dr.reload, actor: manager,
                                      amounts: { cash_pm.id => { collected_amount: "470", refund_amount: "0" } },
                                      notes: "Recount").call

    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Branch Review Automatically Cancelled")
  end

  it "shows the override event with reason when a deposit is recorded/corrected AFTER approval" do
    role = business.permission_roles.create!(name: "Super Admin #{SecureRandom.hex(3)}",
                                              permissions: %w[view_daily_reconciliation create_till_deposit
                                                               close_till_session override_review_requirement])
    manager.update_column(:permission_role_id, role.id)

    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 200, refund_amount: 0)

    # First deposit + approval happen normally (the standard order).
    Finance::TillDepositRecorder.new(
      dr.id, actor: manager, params: { payment_method_id: cash_pm.id, amount: "100.00", deposited_at: Time.current.to_s }
    ).call
    dr.reload
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call

    # A second/corrective deposit after approval requires the override.
    Finance::TillDepositRecorder.new(
      dr.id, actor: manager,
      params: { payment_method_id: cash_pm.id, amount: "100.00", deposited_at: Time.current.to_s,
                override_review_reason: "Cashier found extra cash after approval" }
    ).call

    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Deposit Recorded/Corrected After Approval (Override)")
    expect(response.body).to include("Cashier found extra cash after approval")
  end
end
