require "rails_helper"

# Regression coverage for "register a confirmed bank dispute as a real
# deposit, then settle whatever remains." This reuses the existing pipeline
# end to end — nothing new was built for this:
#
#   Finance::BankDisputes::DepositConfirmer (confirm_deposit action)
#     -> Finance::TillDepositRecorder (creates the real TillDeposit,
#        reconciles/creates a RemainingDepositBalance for any shortfall)
#     -> Finance::RemainingDepositBalanceSettler (partial/full settlement of
#        the shortfall via the existing Remaining Deposit Balance workflow)
#
# The dispute must reach "confirmed_successful" (new -> submitted_to_bank ->
# under_investigation -> confirmed_successful) before it can be registered as
# a deposit — this is the existing, audited lifecycle; nothing here bypasses
# it.
RSpec.describe "Registering a confirmed Bank Dispute as a deposit, then settling the remainder", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:actor) do
    user_with("view_daily_reconciliation", "manage_bank_disputes", "settle_remaining_deposit_balance",
              "create_till_deposit", "close_till_session", "view_session_totals",
              "view_all_employee_reconciliation_summary")
  end

  def build_dr(expected_amount:)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: expected_amount, refund_amount: 0)
    dr
  end

  def open_atm_dispute(dr, amount:)
    BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: actor,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: amount, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )
  end

  # Walks a dispute through the existing, audited lifecycle to
  # confirmed_successful — the only state confirm_deposit will act on.
  def confirm_successful!(dispute)
    %w[submitted_to_bank under_investigation confirmed_successful].each do |status|
      patch "/finance/bank_disputes/#{dispute.id}/#{transition_route(status)}", params: {}
      expect(response).to have_http_status(:found)
      dispute.reload
    end
    expect(dispute.status).to eq("confirmed_successful")
  end

  def transition_route(status)
    { "submitted_to_bank" => "submit_to_bank", "under_investigation" => "start_investigation",
      "confirmed_successful" => "confirm_successful" }.fetch(status)
  end

  def register_dispute_as_deposit!(dispute, payment_method: cash_pm)
    patch confirm_deposit_finance_bank_dispute_path(dispute), params: { payment_method_id: payment_method.id }
    dispute.reload
  end

  before { sign_in actor }

  it "case 1+6+7+8: expected 12,815 / dispute 12,750 -> remaining 65, dispute counted exactly once, traceable, no duplicate movement" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)

    expect { register_dispute_as_deposit!(dispute) }.to change(TillDeposit, :count).by(1)
    expect(response).to redirect_to(finance_bank_dispute_path(dispute))

    expect(dispute.status).to eq("closed")
    expect(dispute.till_deposit).to be_present
    expect(dispute.till_deposit.amount).to eq(12_750)

    dr.reload
    # Counted exactly once: total_deposited holds the real money movement,
    # open_atm_dispute_amount is now 0 because the dispute is resolved
    # (closed) — no double subtraction of the same 12,750.
    expect(dr.total_deposited).to eq(12_750)
    expect(dr.open_atm_dispute_amount).to eq(0)
    expect(dr.pending_deposit_amount).to eq(65)

    rdb = dr.remaining_deposit_balances.open.sole
    expect(rdb.remaining_amount).to eq(65)
    expect(rdb.till_deposit).to eq(dispute.till_deposit)

    # Traceable both ways: deposit -> dispute, dispute -> deposit.
    expect(dispute.till_deposit.bank_disputes).to include(dispute)
  end

  it "case 2+4: settling the full remaining amount drives it to 0 and closes the balance" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)
    register_dispute_as_deposit!(dispute)

    rdb = dr.remaining_deposit_balances.open.sole
    result = Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: actor, amount: 65).call

    expect(result.ok?).to be true
    expect(rdb.reload.remaining_amount).to eq(0)
    expect(rdb.status).to eq("settled")
    # pending_deposit_amount tracks cash still owed via the Deposit workflow
    # (expected - deposited - open disputes) and is unaffected by settling an
    # RDB through a different channel; total_remaining_balance (the "still
    # outstanding" figure the Cash Reconciliation UI actually shows) is what
    # must reach zero once the shortfall itself is settled.
    expect(dr.reload.total_remaining_balance).to eq(0)
  end

  it "case 3: partial settlement — settling 30 of 65 leaves 35 remaining and stays open" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)
    register_dispute_as_deposit!(dispute)

    rdb = dr.remaining_deposit_balances.open.sole
    result = Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: actor, amount: 30).call

    expect(result.ok?).to be true
    expect(rdb.reload.remaining_amount).to eq(35)
    expect(rdb.status).to eq("open")
  end

  it "case 3+4 combined: 65 -> settle 30 -> 35 -> settle 35 -> 0" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)
    register_dispute_as_deposit!(dispute)
    rdb = dr.remaining_deposit_balances.open.sole

    Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: actor, amount: 30).call
    expect(rdb.reload.remaining_amount).to eq(35)

    Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: actor, amount: 35).call
    expect(rdb.reload.remaining_amount).to eq(0)
    expect(rdb.status).to eq("settled")
  end

  it "case 5: does not allow settling more than the remaining amount" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)
    register_dispute_as_deposit!(dispute)
    rdb = dr.remaining_deposit_balances.open.sole

    result = Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: actor, amount: 70).call

    expect(result.ok?).to be false
    expect(rdb.reload.remaining_amount).to eq(65)
    expect(rdb.status).to eq("open")
  end

  it "case 5b: a full settlement followed by any further settlement attempt is rejected (already closed)" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)
    register_dispute_as_deposit!(dispute)
    rdb = dr.remaining_deposit_balances.open.sole
    Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: actor, amount: 65).call

    result = Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: actor, amount: 1).call
    expect(result.ok?).to be false
  end

  it "case 9: a rejected (not confirmed) dispute cannot be registered as a deposit" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    patch "/finance/bank_disputes/#{dispute.id}/submit_to_bank", params: {}
    patch "/finance/bank_disputes/#{dispute.id}/start_investigation", params: {}
    patch "/finance/bank_disputes/#{dispute.id}/reject", params: {}
    dispute.reload
    expect(dispute.status).to eq("rejected")

    expect {
      patch confirm_deposit_finance_bank_dispute_path(dispute), params: { payment_method_id: cash_pm.id }
    }.not_to change(TillDeposit, :count)

    expect(response).to redirect_to(root_path) # policy gate — confirm_deposit? is false for a non-confirmed dispute
    expect(dispute.reload.till_deposit).to be_nil
  end

  it "case 9b: a still-open (new) dispute cannot be registered as a deposit either" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)

    expect {
      patch confirm_deposit_finance_bank_dispute_path(dispute), params: { payment_method_id: cash_pm.id }
    }.not_to change(TillDeposit, :count)

    expect(dispute.reload.till_deposit).to be_nil
  end

  it "case 10: existing permission gates still apply — an actor without settle_remaining_deposit_balance cannot settle" do
    limited_actor = user_with("view_daily_reconciliation", "manage_bank_disputes", "create_till_deposit",
                              "close_till_session")
    dr = build_dr(expected_amount: 12_815)
    dr.till_session.update!(depositor_id: limited_actor.id)
    dispute = BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: limited_actor,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: 12_750, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )

    sign_in limited_actor
    %w[submit_to_bank start_investigation confirm_successful].each do |route|
      patch "/finance/bank_disputes/#{dispute.id}/#{route}", params: {}
    end
    dispute.reload
    patch confirm_deposit_finance_bank_dispute_path(dispute), params: { payment_method_id: cash_pm.id }
    dispute.reload

    rdb = dr.reload.remaining_deposit_balances.open.sole
    patch settle_finance_remaining_deposit_balance_path(rdb), params: { amount: 65 }

    expect(response).to redirect_to(root_path)
    expect(rdb.reload.remaining_amount).to eq(65)
  end

  it "case 11: an ordinary cash deposit with no bank dispute involved still works exactly as before" do
    dr = build_dr(expected_amount: 500)

    result = Finance::TillDepositRecorder.new(
      dr.id, actor: actor, params: { payment_method_id: cash_pm.id, amount: 500, deposited_at: Time.current }
    ).call

    expect(result.ok?).to be true
    expect(dr.reload.total_deposited).to eq(500)
    expect(dr.pending_deposit_amount).to eq(0)
    expect(dr.remaining_deposit_balances.open).to be_empty
  end

  it "case 12: multiple bank disputes on the same day — only the registered one becomes a deposit, the other stays open and still reduces remaining" do
    dr = build_dr(expected_amount: 12_815)
    dispute1 = open_atm_dispute(dr, amount: 10_000)
    dispute2 = open_atm_dispute(dr, amount: 2_000)
    confirm_successful!(dispute1)

    register_dispute_as_deposit!(dispute1)

    dr.reload
    # dispute1 is now closed (resolved) and its 10,000 is a real deposit;
    # dispute2 is still open and continues to reduce the remaining amount —
    # 12,815 - 10,000 (deposit) - 2,000 (still-open dispute) = 815.
    expect(dr.total_deposited).to eq(10_000)
    expect(dr.open_atm_dispute_amount).to eq(2_000)
    expect(dr.pending_deposit_amount).to eq(815)

    rdb = dr.remaining_deposit_balances.open.sole
    expect(rdb.remaining_amount).to eq(815)
  end

  it "renders the Cash Reconciliation card with expected/deposited/remaining" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)
    register_dispute_as_deposit!(dispute)

    get finance_daily_reconciliation_path(dr)
    expect(response).to have_http_status(:ok)

    doc = Nokogiri::HTML(response.body)
    section = doc.at_css("#cash-reconciliation")
    expect(section.text).to include("12,815")
    expect(section.text).to include("12,750")
    expect(section.text).to include(I18n.t("finance.daily_reconciliations.show.outstanding_balance"))
    expect(section.text).to include("65")
  end

  it "shows the bank-dispute origin badge next to the deposit in the per-employee breakdown" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)
    register_dispute_as_deposit!(dispute)

    # Minimal custody event so Finance::EmployeeReconciliationSummarizer has
    # something to attribute to `actor` for this DR — a self-deposit handover
    # closing out the cash payment method's full session amount.
    close = TillHandover.create!(daily_reconciliation: dr, from_user: actor, self_deposit: true,
                                 accepted_at: Time.current)
    TillHandoverAmount.create!(till_handover: close, payment_method: cash_pm, payment_method_name: "Cash",
                               collected_amount: 12_815, refund_amount: 0)

    get finance_daily_reconciliation_path(dr)
    doc = Nokogiri::HTML(response.body)
    section = doc.at_css("#cash-reconciliation")

    expect(section.text).to include(I18n.t("finance.daily_reconciliations.show.sections.cash.bank_dispute_origin"))
    link = section.at_css("a[href='#{finance_bank_dispute_path(dispute)}']")
    expect(link).to be_present
  end
end
