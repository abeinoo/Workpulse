require "rails_helper"

RSpec.describe "TillRefunds — independent refund/return, decoupled from Cashier Handover",
               type: :request do
  let(:business)     { create(:business) }
  let(:branch)       { create(:branch, business: business) }
  let(:other_branch) { create(:branch, business: business) }
  let(:cash_pm)      { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:card_pm)      { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true) }

  def user_with(*perms, scopes: {})
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: scopes
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def open_dr_for(target_branch, holder:)
    dr = DailyReconciliation.create!(
      branch: target_branch, business: business, state: "open",
      opened_at: 1.hour.ago, business_date: Date.current
    )
    TillSession.create!(daily_reconciliation: dr, current_holder: holder)
    dr
  end

  let(:cashier) { create(:user, business: business) }
  let!(:dr)     { open_dr_for(branch, holder: cashier) }

  def refund_params(pm: cash_pm, amount: "50", idempotency_key: nil, dr_id: dr.id)
    {
      till_refund: {
        daily_reconciliation_id: dr_id,
        payment_method_id:       pm.id,
        amount:                  amount,
        notes:                   "Customer return",
        idempotency_key:         idempotency_key
      }
    }
  end

  # ── 6. Super Admin can refund ──────────────────────────────────────────
  it "allows Super Admin (no shift assignment, no branch management) to record a refund" do
    owner = create(:user, :owner, business: business)

    sign_in owner
    post till_refunds_path, params: refund_params

    expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
    expect(dr.till_refunds.count).to eq(1)
  end

  # ── 1, 2, 3. Independent of TillHandover, till stays open ──────────────
  it "records the refund without creating any TillHandover, and the till stays open" do
    owner = create(:user, :owner, business: business)

    sign_in owner
    post till_refunds_path, params: refund_params(amount: "75")

    dr.reload
    expect(dr.till_refunds.count).to eq(1)
    expect(dr.till_handovers.count).to eq(0)
    expect(dr).to be_open
    expect(dr.till_session.current_holder).to eq(cashier)
    expect(dr.till_refunds.first.amount).to eq(75)
  end

  # ── 4. Reflected correctly on the DR ────────────────────────────────────
  it "is reflected on DailyReconciliation#total_refunds immediately, before any handover" do
    owner = create(:user, :owner, business: business)

    sign_in owner
    post till_refunds_path, params: refund_params(amount: "40")

    expect(dr.reload.total_refunds).to eq(40)
  end

  # ── 11. Multiple refunds before handover ────────────────────────────────
  it "correctly sums multiple refunds across payment methods before any handover" do
    owner = create(:user, :owner, business: business)
    sign_in owner

    post till_refunds_path, params: refund_params(pm: cash_pm, amount: "20")
    post till_refunds_path, params: refund_params(pm: cash_pm, amount: "15")
    post till_refunds_path, params: refund_params(pm: card_pm, amount: "10")

    dr.reload
    expect(dr.till_refunds.count).to eq(3)
    expect(dr.total_refunds).to eq(45)
    expect(dr.refunds_by_payment_method[cash_pm.id]).to eq(35)
    expect(dr.refunds_by_payment_method[card_pm.id]).to eq(10)
  end

  # ── 5, 10. Later handover includes the refund exactly once; handover flow unaffected ──
  it "folds standalone refunds into session_amounts exactly once when the day closes, without double counting" do
    owner = create(:user, :owner, business: business)
    sign_in owner

    post till_refunds_path, params: refund_params(pm: cash_pm, amount: "30")
    expect(dr.reload.total_refunds).to eq(30)

    # Cashier closes the day (self-deposit), typing their own observed refund total.
    result = Finance::TillHandoverCreator.new(
      actor: cashier, daily_reconciliation_id: dr.id,
      params: { self_deposit: "1", depositor_type: "self",
                amounts: { cash_pm.id.to_s => { collected_amount: "500", refund_amount: "5" } } }
    ).call
    expect(result.ok?).to be(true), result.error

    session_amount = dr.reload.session_amounts.find_by(payment_method: cash_pm)
    # 5 (handover-typed) + 30 (standalone) = 35, counted exactly once.
    expect(session_amount.refund_amount).to eq(35)
    expect(session_amount.collected_amount).to eq(500)

    # Re-running the same sync (e.g. via Finance::DayCloseEditor) must not
    # double the standalone refund a second time.
    Finance::TillHandoverCreator.sync_session_amounts!(dr.reload, dr.day_close_handover)
    expect(dr.reload.session_amounts.find_by(payment_method: cash_pm).refund_amount).to eq(35)
  end

  # ── 7. Area Manager can refund within authorized branches ──────────────
  it "allows an Area Manager with process_till_refund to refund a branch in their BranchScope" do
    area_manager = user_with("view_daily_reconciliation", "process_till_refund",
                             scopes: { "process_till_refund" => "area" })
    branch.update!(area_manager: area_manager)

    sign_in area_manager
    post till_refunds_path, params: refund_params

    expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
    expect(dr.till_refunds.count).to eq(1)
  end

  # ── 8. Area Manager cannot refund outside BranchScope ───────────────────
  it "blocks an Area Manager from refunding a branch outside their BranchScope" do
    area_manager = user_with("view_daily_reconciliation", "process_till_refund",
                             scopes: { "process_till_refund" => "area" })
    # area_manager manages `other_branch`, not `branch` — dr belongs to `branch`.
    other_branch.update!(area_manager: area_manager)

    sign_in area_manager
    post till_refunds_path, params: refund_params

    expect(response).to redirect_to(root_path)
    expect(dr.till_refunds.count).to eq(0)
  end

  # ── 9. User without permission is blocked ───────────────────────────────
  it "blocks a user who only has close_till_session (no process_till_refund)" do
    cashier_only = user_with("view_daily_reconciliation", "close_till_session")

    sign_in cashier_only
    post till_refunds_path, params: refund_params

    expect(response).to redirect_to(root_path)
    expect(dr.till_refunds.count).to eq(0)
  end

  it "blocks a plain user with no permissions at all" do
    unpermitted = user_with("view_daily_reconciliation")

    sign_in unpermitted
    post till_refunds_path, params: refund_params

    expect(response).to redirect_to(root_path)
    expect(dr.till_refunds.count).to eq(0)
  end

  # ── 12. Idempotency — no duplicate on resubmit ──────────────────────────
  it "does not duplicate the refund when the exact same request is resubmitted (idempotency_key)" do
    owner = create(:user, :owner, business: business)
    key = SecureRandom.uuid

    sign_in owner
    post till_refunds_path, params: refund_params(amount: "60", idempotency_key: key)
    post till_refunds_path, params: refund_params(amount: "60", idempotency_key: key)

    expect(dr.reload.till_refunds.count).to eq(1)
    expect(dr.total_refunds).to eq(60)
  end

  # ── Business rule guards ─────────────────────────────────────────────────
  it "rejects a refund once the Daily Reconciliation is no longer open" do
    owner = create(:user, :owner, business: business)
    dr.update!(state: "closed", closed_at: Time.current)

    sign_in owner
    post till_refunds_path, params: refund_params

    expect(dr.till_refunds.count).to eq(0)
  end

  it "existing Cashier Handover creation still works normally, unaffected by the refund feature" do
    accept_perm_user = user_with("view_daily_reconciliation", "accept_till_handover")
    sender = user_with("view_daily_reconciliation", "close_till_session")
    create(:shift_assignment, business: business, user: sender, branch: branch)
    dr.till_session.update!(current_holder: sender)

    sign_in sender
    post till_handovers_path, params: {
      till_handover: { to_user_id: accept_perm_user.id,
                        amounts: { cash_pm.id.to_s => { collected_amount: "100", refund_amount: "0" } } }
    }

    expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
    expect(dr.till_handovers.where(from_user: sender).count).to eq(1)
  end
end
