require "rails_helper"

RSpec.describe Finance::BulkShortageCashSettler, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms, biz: business)
    role = biz.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: biz).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:actor) do
    user_with("view_daily_reconciliation", "settle_remaining_deposit_balance", "receive_shortage_settlement_cash")
  end
  let(:cashier_a) { create(:user, business: business) }
  let(:cashier_b) { create(:user, business: business) }
  let!(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let!(:visa_pm)  { PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true) }

  def make_dr(date)
    DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                opened_at: date.to_time + 9.hours, closed_at: date.to_time + 22.hours,
                                business_date: date)
  end

  def shortage(dr, amount, cashier)
    RemainingDepositBalance.create!(daily_reconciliation: dr, responsible_user: cashier, created_by: actor,
                                    business: business, branch: branch, amount: amount,
                                    remaining_amount: amount, status: "open")
  end

  let(:day1) { make_dr(Date.new(2026, 11, 1)) }
  let(:day2) { make_dr(Date.new(2026, 11, 2)) }
  let!(:rdb1) { shortage(day1, 100, cashier_a) }
  let!(:rdb2) { shortage(day2, 150, cashier_b) }

  def settle_cash(ids: [ day1.id, day2.id ], by: actor, pm_id: nil, ref: "RC-77", notes: "Cashier paid back")
    described_class.new(daily_reconciliation_ids: ids, actor: by, notes: notes,
                        payment_method_id: pm_id, reference_number: ref).call
  end

  def error_for(key) = I18n.t("finance.daily_reconciliations.errors.bulk_settle.#{key}")

  def footprint
    { ledger: RemainingDepositBalanceTransaction.count, custody: CustodyTransaction.count,
      deposits: TillDeposit.count, session_amounts: TillSessionAmount.count,
      open_rdbs: RemainingDepositBalance.open.count }
  end

  describe "successful cash settlement" do
    it "settles every shortage in full with one Cash settlement row each" do
      result = settle_cash
      expect(result).to be_ok
      expect([ result.total, result.settled_count, result.record ]).to eq([ 250, 2, cash_pm ])

      [ rdb1, rdb2 ].each do |rdb|
        rdb.reload
        expect([ rdb.status, rdb.remaining_amount ]).to eq([ "settled", 0 ])
        row = rdb.balance_transactions.settlements.sole
        expect([ row.amount, row.payment_method, row.reference_number, row.notes ])
          .to eq([ rdb.amount, cash_pm, "RC-77", "Cashier paid back" ])
        expect(row.custody_transaction_id).to be_nil
      end
    end

    it "keeps each original cashier" do
      settle_cash
      expect([ rdb1.reload.responsible_user, rdb2.reload.responsible_user ]).to eq([ cashier_a, cashier_b ])
    end

    it "creates no custody credit, deposit or till session amount" do
      before = footprint
      settle_cash
      after = footprint
      expect(after.except(:ledger, :open_rdbs)).to eq(before.except(:ledger, :open_rdbs))
      expect(after[:ledger] - before[:ledger]).to eq(2)
    end

    it "is the same ledger record the single-shortage Receive writes with Cash" do
      settle_cash
      single_rdb = shortage(make_dr(Date.new(2026, 11, 3)), 40, cashier_a)
      Finance::RemainingDepositBalanceSettler.new(single_rdb.id, actor: actor, amount: 40,
                                                  payment_method_id: cash_pm.id).call
      bulk_row   = rdb1.balance_transactions.settlements.sole
      single_row = single_rdb.balance_transactions.settlements.sole
      expect([ bulk_row.transaction_type, bulk_row.payment_method_id ])
        .to eq([ single_row.transaction_type, single_row.payment_method_id ])
    end

    it "audits each balance with the destination and the bulk reference" do
      expect { settle_cash }.to change(AuditLog, :count).by(2)
      logs = AuditLog.where(action: "settle", auditable: [ rdb1, rdb2 ])
      expect(logs.map { |l| l.metadata["settlement_destination"] }.uniq).to eq([ "cash_payment_method" ])
      expect(logs.map { |l| l.metadata["bulk_reference"] }.uniq.size).to eq(1)
      expect(logs.map { |l| l.metadata["payment_method_id"] }.uniq).to eq([ cash_pm.id ])
    end

    it "counts toward Settled Later" do
      settle_cash
      expect(day2.reload.total_settled_later).to eq(150)
    end
  end

  # Load-order regression: Finance::DashboardFilters defines Finance::Result; a
  # bare `Result` inside a subclass would resolve to it (ArgumentError seen in a
  # combined spec run, 2026-11-15).
  it "builds its result even when Finance::Result is loaded" do
    expect(Finance::DashboardFilters).to be_a(Class)
    expect(Finance::Result).not_to eq(Finance::BulkShortageSettlement::Result)
    result = settle_cash
    expect(result).to be_ok
    expect(result).to be_a(Finance::BulkShortageSettlement::Result)
  end

  describe "cash payment method selection" do
    it "requires a choice when several active Cash methods exist" do
      PaymentMethod.create!(business: business, name: "Cash 2", settlement_type: "cash", active: true)
      expect(settle_cash.error).to eq(error_for(:cash_method_required))
    end

    it "uses the chosen one of several Cash methods" do
      cash2 = PaymentMethod.create!(business: business, name: "Cash 2", settlement_type: "cash", active: true)
      settle_cash(pm_id: cash2.id)
      expect(rdb1.reload.balance_transactions.settlements.sole.payment_method).to eq(cash2)
    end

    it "rejects a non-cash method (e.g. a tampered card id)" do
      before = footprint
      expect(settle_cash(pm_id: visa_pm.id).error).to eq(error_for(:cash_method_invalid))
      expect(footprint).to eq(before)
    end

    it "rejects another business's Cash method" do
      foreign = PaymentMethod.create!(business: create(:business), name: "Cash", settlement_type: "cash", active: true)
      expect(settle_cash(pm_id: foreign.id).error).to eq(error_for(:cash_method_invalid))
    end

    it "rejects when no active Cash method exists" do
      cash_pm.update!(active: false)
      expect(settle_cash.error).to eq(error_for(:cash_method_missing))
      expect(RemainingDepositBalance.open.count).to eq(2)
    end
  end

  describe "authorization and isolation" do
    it "requires receive_shortage_settlement_cash" do
      no_cash = user_with("view_daily_reconciliation", "settle_remaining_deposit_balance")
      before = footprint
      expect(settle_cash(by: no_cash).error).to eq(error_for(:not_authorized))
      expect(footprint).to eq(before)
    end

    it "requires settle_remaining_deposit_balance as well" do
      # A role cannot hold receive_… without settle_… (dependency), so simulate it.
      only_cash = user_with("view_daily_reconciliation")
      allow(only_cash).to receive(:can?).and_call_original
      allow(only_cash).to receive(:can?).with(:receive_shortage_settlement_cash).and_return(true)
      expect(settle_cash(by: only_cash).error).to eq(error_for(:not_authorized))
    end

    it "rejects a DR of another business and settles nothing" do
      other = create(:business)
      foreign_dr = DailyReconciliation.create!(branch: create(:branch, business: other), business: other,
                                               state: "closed", opened_at: 2.days.ago, closed_at: 1.day.ago,
                                               business_date: Date.new(2026, 11, 4))
      before = footprint
      expect(settle_cash(ids: [ day1.id, foreign_dr.id ]).error).to eq(error_for(:not_found))
      expect(footprint).to eq(before)
    end

    # Notes are optional (owner decision 2026-11-15); traceability never depends on them.
    [ nil, "", "   " ].each do |blank|
      it "settles without notes (#{blank.inspect}) — NULL stored, every reference kept" do
        expect(settle_cash(notes: blank)).to be_ok
        [ rdb1, rdb2 ].each do |rdb|
          row = rdb.reload.balance_transactions.settlements.sole
          expect([ row.notes, row.payment_method, row.reference_number ]).to eq([ nil, cash_pm, "RC-77" ])
        end
        logs = AuditLog.where(action: "settle", auditable: [ rdb1, rdb2 ])
        expect(logs.size).to eq(2)
        expect(logs.map { |l| l.metadata["bulk_reference"] }.uniq.size).to eq(1)
        expect(logs.map { |l| l.metadata["payment_method_id"] }.uniq).to eq([ cash_pm.id ])
        expect(logs.map { |l| l.metadata["responsible_user_id"] }).to contain_exactly(cashier_a.id, cashier_b.id)
      end
    end
  end

  describe "duplicates, mutual exclusivity and all-or-nothing" do
    it "rejects a repeated submission without a second settlement row" do
      settle_cash
      before = footprint
      expect(settle_cash.error).to eq(error_for(:already_settled))
      expect(footprint).to eq(before)
    end

    it "cannot settle in cash what was already credited to custody (and vice versa)" do
      account = create(:custody_account, business: business)
      custody_actor = user_with("view_daily_reconciliation", "settle_remaining_deposit_balance",
                                "view_employee_balances", "manage_employee_balances")
      Finance::BulkShortageCustodySettler.new(daily_reconciliation_ids: [ day1.id ], custody_account_id: account.id,
                                              actor: custody_actor, notes: "x").call
      expect(settle_cash(ids: [ day1.id ]).error).to eq(error_for(:already_settled))

      settle_cash(ids: [ day2.id ])
      again = Finance::BulkShortageCustodySettler.new(daily_reconciliation_ids: [ day2.id ],
                                                      custody_account_id: account.id,
                                                      actor: custody_actor, notes: "x").call
      expect(again.error).to eq(error_for(:already_settled))
      expect(rdb1.reload.balance_transactions.settlements.count).to eq(1)
      expect(rdb2.reload.balance_transactions.settlements.count).to eq(1)
      expect(CustodyTransaction.where(source: rdb2)).to be_empty
    end

    it "rejects everything when one selected day was settled meanwhile" do
      Finance::RemainingDepositBalanceSettler.new(rdb2.id, actor: actor, amount: 150, notes: "x").call
      before = footprint
      expect(settle_cash.error).to eq(error_for(:already_settled))
      expect(footprint).to eq(before)
      expect(rdb1.reload).to be_open
    end

    it "rolls everything back when a write fails part-way" do
      calls = 0
      allow_any_instance_of(RemainingDepositBalance).to receive(:update!).and_wrap_original do |m, *args|
        calls += 1
        raise ActiveRecord::RecordInvalid, m.receiver if calls == 2

        m.call(*args)
      end
      before = footprint
      expect(settle_cash).not_to be_ok
      expect(footprint).to eq(before)
    end

    it "rolls everything back when an audit entry cannot be written" do
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "boom")
      before = footprint
      expect(settle_cash.error).to eq(error_for(:audit_failed))
      expect(footprint).to eq(before)
    end
  end
end
