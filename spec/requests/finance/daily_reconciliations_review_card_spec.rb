require "rails_helper"

RSpec.describe "Finance::DailyReconciliations show — Deposit Review card", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:manager)  { user_with("view_daily_reconciliation", "review_daily_reconciliation") }
  let(:no_perm)  { user_with("view_daily_reconciliation") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: manager.id) }

  def record_deposit!
    dr.till_deposits.create!(payment_method: cash_pm, deposited_by: manager, amount: 50, deposited_at: Time.current)
    dr.update_columns(state: "deposited")
    dr.reload
  end

  it "shows the waiting-for-deposit placeholder and no Approve action before any deposit exists" do
    sign_in manager
    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include(I18n.t("finance.daily_reconciliations.show.waiting_for_deposit_placeholder"))
    expect(response.body).not_to include("Approve Deposit")
  end

  it "shows Pending Deposit Review with an Approve Deposit button once a deposit is recorded, for a permissioned user" do
    record_deposit!
    sign_in manager
    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Pending Deposit Review")
    expect(response.body).to include("Approve Deposit")
  end

  it "does not show the Approve Deposit button for a user without the permission" do
    record_deposit!
    sign_in no_perm
    get finance_daily_reconciliation_path(dr)

    expect(response.body).not_to include("Approve Deposit")
  end

  it "shows Reviewed By / Reviewed At with a Cancel Approval button once approved" do
    record_deposit!
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call

    sign_in manager
    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Reviewed By")
    expect(response.body).to include("Reviewed At")
    expect(response.body).to include(manager.full_name)
    expect(response.body).to include("Cancel Approval")
  end

  it "hides the Cancel Approval button once bank verification is complete" do
    record_deposit!
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call
    verifier = user_with("view_daily_reconciliation", "verify_daily_reconciliation")
    Finance::DailyReconciliationVerifier.new(dr.id, actor: verifier).call

    sign_in manager
    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include(manager.full_name)
    expect(response.body).not_to include("Cancel Approval")
  end

  it "shows Review Invalidated when a prior approval was automatically cancelled" do
    handover = TillHandover.create!(daily_reconciliation: dr, from_user: manager, self_deposit: true,
                                     opening_float_declaration: false, fresha_date: dr.business_date)
    TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 370, refund_amount: 0, kind: "operational")
    record_deposit!
    Finance::DailyReconciliationReviewer.new(dr.id, actor: manager).call
    # DayCloseEditor can no longer fire post-deposit (it explicitly rejects
    # once deposited?) — SessionAmountsEditor is the one correction path that
    # can still run after a deposit/approval exists, so it's what actually
    # triggers clear_review! in this order.
    Finance::SessionAmountsEditor.new(dr.reload, actor: manager,
                                      amounts: { cash_pm.id => { collected_amount: "470", refund_amount: "0" } },
                                      notes: "Recount").call

    sign_in manager
    get finance_daily_reconciliation_path(dr)

    expect(response.body).to include("Review Invalidated")
    expect(response.body).to include("Approve Deposit")
  end
end
