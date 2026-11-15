require "rails_helper"

RSpec.describe Finance::BulkShortageCustodySettler, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms, biz: business, scope: "business_wide")
    role = biz.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { scope }
    )
    create(:user, business: biz).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # Deliberately WITHOUT any Employee Balances permission: crediting custody is
  # part of the settlement workflow (owner decision 2026-11-15).
  let(:actor) { user_with("view_daily_reconciliation", "settle_remaining_deposit_balance") }

  let(:cashier_a) { create(:user, business: business) }
  let(:cashier_b) { create(:user, business: business) }
  let(:recipient) { create(:user, business: business) }
  let!(:account)  { create(:custody_account, business: business, user: recipient) }

  def make_dr(date)
    DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                opened_at: date.to_time + 9.hours, closed_at: date.to_time + 22.hours,
                                business_date: date)
  end

  def shortage(dr, amount, cashier, status: "open")
    RemainingDepositBalance.create!(
      daily_reconciliation: dr, responsible_user: cashier, created_by: actor,
      business: business, branch: branch, amount: amount,
      remaining_amount: status == "open" ? amount : 0, status: status,
      closed_at: status == "open" ? nil : Time.current
    )
  end

  let(:day1) { make_dr(Date.new(2026, 11, 1)) }
  let(:day2) { make_dr(Date.new(2026, 11, 2)) }
  let(:day3) { make_dr(Date.new(2026, 11, 3)) }
  let!(:rdb1) { shortage(day1, 100, cashier_a) }
  let!(:rdb2) { shortage(day2, 150, cashier_b) }
  let!(:rdb3) { shortage(day3, 200, cashier_a) }

  def settle(ids: [ day1.id, day2.id, day3.id ], account_id: account.id, by: actor, notes: "Collected by supervisor")
    described_class.new(daily_reconciliation_ids: ids, custody_account_id: account_id,
                        actor: by, notes: notes).call
  end

  # Every financial table the settlement must leave alone, or change by exactly
  # what it should.
  def footprint
    { custody: CustodyTransaction.count, ledger: RemainingDepositBalanceTransaction.count,
      deposits: TillDeposit.count, session_amounts: TillSessionAmount.count,
      open_rdbs: RemainingDepositBalance.open.count, balance: account.reload.current_balance }
  end

  describe "successful bulk settlement (100 + 150 + 200)" do
    it "credits the full 450 to the selected employee's custody account" do
      result = settle
      expect(result).to be_ok
      expect(result.total).to eq(450)
      expect(result.settled_count).to eq(3)
      expect(account.reload.current_balance).to eq(450)
      expect(account.computed_balance).to eq(450)
    end

    it "posts one positive Shortage Settlement Deposit per shortage, each sourced from its balance" do
      settle
      txns = account.custody_transactions.order(:id)
      expect(txns.map(&:txn_type).uniq).to eq([ "shortage_settlement_deposit" ])
      expect(txns.map(&:amount)).to eq([ 100, 150, 200 ])
      expect(txns.map(&:source)).to eq([ rdb1, rdb2, rdb3 ])
      expect(txns.map(&:created_by).uniq).to eq([ actor ])
      expect(txns.first.notes).to include(cashier_a.full_name, "Collected by supervisor")
    end

    it "shows on the recipient's custody statement and nowhere else" do
      other = create(:custody_account, business: business, user: cashier_a)
      settle
      expect(CustodyTransaction.where(custody_account: account).sum(:amount)).to eq(450)
      expect(other.custody_transactions).to be_empty
    end

    it "closes every balance as settled through an append-only settlement row naming the custody credit" do
      settle
      [ rdb1, rdb2, rdb3 ].each do |rdb|
        rdb.reload
        expect(rdb).to be_settled
        expect(rdb.remaining_amount).to eq(0)
        expect(rdb.closed_at).to be_present
        row = rdb.balance_transactions.settlements.sole
        expect(row.amount).to eq(rdb.amount)
        expect(row.payment_method_id).to be_nil
        expect(row.custody_settlement?).to be(true)
        expect(row.custody_transaction.source).to eq(rdb)
        expect(row.custody_transaction.custody_account).to eq(account)
      end
    end

    it "keeps the original cashier on every shortage (mixed cashiers allowed)" do
      settle
      expect([ rdb1, rdb2, rdb3 ].map { |r| r.reload.responsible_user }).to eq([ cashier_a, cashier_b, cashier_a ])
    end

    it "creates no cash drawer, deposit or payment-method record" do
      before = footprint
      settle
      after = footprint
      expect(after[:deposits]).to eq(before[:deposits])
      expect(after[:session_amounts]).to eq(before[:session_amounts])
      expect(RemainingDepositBalanceTransaction.where.not(payment_method_id: nil)).to be_empty
      expect(CustodyTransaction.where.not(txn_type: "shortage_settlement_deposit")).to be_empty
    end

    it "counts toward the DR's Settled Later total" do
      settle
      expect(day2.reload.total_settled_later).to eq(150)
    end

    it "audits each balance and the bulk operation with every reference" do
      expect { settle }.to change(AuditLog, :count).by(4)
      bulk = AuditLog.find_by!(auditable: account, action: "bulk_shortage_settlement")
      expect(bulk.metadata).to include("total" => "450.0", "recipient_user_id" => recipient.id,
                                       "daily_reconciliation_ids" => [ day1.id, day2.id, day3.id ].sort,
                                       "remaining_deposit_balance_ids" => [ rdb1.id, rdb2.id, rdb3.id ])
      per = AuditLog.find_by!(auditable: rdb2, action: "settle")
      expect(per.metadata).to include("settlement_destination" => "custody_account",
                                      "responsible_user_id" => cashier_b.id,
                                      "recipient_user_id" => recipient.id,
                                      "bulk_reference" => bulk.metadata["bulk_reference"])
    end

    it "ignores already-closed balances on a selected day that still has an open one" do
      written_off = shortage(day1, 30, cashier_a, status: "written_off")
      expect(settle.total).to eq(450)
      expect(written_off.reload.balance_transactions).to be_empty
    end
  end

  # Load-order regression: Finance::DashboardFilters defines Finance::Result; a
  # bare `Result` inside a subclass would resolve to it (ArgumentError seen in a
  # combined spec run, 2026-11-15).
  it "builds its result even when Finance::Result is loaded" do
    expect(Finance::DashboardFilters).to be_a(Class)
    expect(Finance::Result).not_to eq(Finance::BulkShortageSettlement::Result)
    result = settle
    expect(result).to be_ok
    expect(result).to be_a(Finance::BulkShortageSettlement::Result)
  end

  describe "duplicate and stale submissions" do
    it "rejects a second identical submission without a second credit" do
      settle
      before = footprint
      result = settle
      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.bulk_settle.already_settled"))
      expect(footprint).to eq(before)
    end

    it "rejects everything when one selected day was settled in the meantime" do
      Finance::RemainingDepositBalanceSettler.new(rdb2.id, actor: actor, amount: 150, notes: "x").call
      before = footprint
      expect(settle).not_to be_ok
      expect(footprint).to eq(before)
      expect(rdb1.reload).to be_open
    end

    it "rejects a day whose only shortage is disputed" do
      rdb3.update_columns(status: "disputed", closed_at: Time.current)
      before = footprint
      expect(settle).not_to be_ok
      expect(footprint).to eq(before)
    end
  end

  describe "validation and authorization" do
    def error_for(key) = I18n.t("finance.daily_reconciliations.errors.bulk_settle.#{key}")

    it "requires a selection" do
      expect(settle(ids: []).error).to eq(error_for(:none_selected))
    end

    it "requires a recipient" do
      expect(settle(account_id: nil).error).to eq(error_for(:recipient_required))
    end

    # Notes are optional (owner decision 2026-11-15); traceability never depends on them.
    [ nil, "", "   " ].each do |blank|
      it "settles without notes (#{blank.inspect}) — NULL stored, every reference kept" do
        result = settle(notes: blank)
        expect(result).to be_ok
        expect(account.reload.current_balance).to eq(450)

        [ rdb1, rdb2, rdb3 ].each do |rdb|
          row = rdb.reload.balance_transactions.settlements.sole
          expect(row.notes).to be_nil
          expect(row.custody_transaction.source).to eq(rdb)
          expect(row.custody_transaction.custody_account).to eq(account)
        end

        credit = CustodyTransaction.find_by!(source: rdb2)
        expect(credit.notes).to eq(I18n.t("finance.daily_reconciliations.bulk_settle_custody_note",
                                          date: I18n.l(day2.business_date), branch: branch.name,
                                          cashier: cashier_b.full_name)) # reference only — no made-up reason

        bulk = AuditLog.find_by!(auditable: account, action: "bulk_shortage_settlement")
        expect(bulk.metadata["notes"]).to be_nil
        expect(bulk.metadata).to include("bulk_reference", "recipient_user_id" => recipient.id,
                                         "remaining_deposit_balance_ids" => [ rdb1.id, rdb2.id, rdb3.id ])
        per = AuditLog.find_by!(auditable: rdb2, action: "settle")
        expect(per.metadata).to include("bulk_reference" => bulk.metadata["bulk_reference"],
                                        "responsible_user_id" => cashier_b.id,
                                        "custody_transaction_id" => credit.id)
      end
    end

    it "rejects a custody account of another business" do
      foreign = create(:custody_account)
      expect(settle(account_id: foreign.id).error).to eq(error_for(:recipient_invalid))
    end

    it "rejects a DR of another business without touching anything" do
      other_biz = create(:business)
      foreign_dr = DailyReconciliation.create!(branch: create(:branch, business: other_biz), business: other_biz,
                                               state: "closed", opened_at: 2.days.ago, closed_at: 1.day.ago,
                                               business_date: Date.new(2026, 11, 4))
      before = footprint
      expect(settle(ids: [ day1.id, foreign_dr.id ]).error).to eq(error_for(:not_found))
      expect(footprint).to eq(before)
    end

    it "rejects an inactive custody account" do
      account.update!(active: false)
      expect(settle.error).to eq(error_for(:recipient_inactive))
      expect(rdb1.reload).to be_open
    end

    it "rejects an inactive recipient employee" do
      recipient.update_column(:active, false)
      expect(settle.error).to eq(error_for(:recipient_inactive))
    end

    it "requires settle_remaining_deposit_balance" do
      no_settle = user_with("view_daily_reconciliation", "view_employee_balances", "manage_employee_balances")
      expect(settle(by: no_settle).error).to eq(error_for(:not_authorized))
    end

    it "does not need manage_employee_balances (settle_remaining_deposit_balance is enough)" do
      expect(actor.can?(:manage_employee_balances)).to be(false)
      expect(settle).to be_ok
    end

    describe "branch scope of settle_remaining_deposit_balance" do
      let(:other_branch) { create(:branch, business: business) }
      let(:branch_settler) do
        user_with("view_daily_reconciliation", "settle_remaining_deposit_balance", scope: "branch").tap do |u|
          branch.update_column(:branch_manager_id, u.id)
        end
      end

      it "allows an account at a branch the settler manages" do
        account.update!(branch: branch)
        expect(settle(by: branch_settler)).to be_ok
      end

      it "refuses an account at another branch, settling nothing" do
        account.update!(branch: other_branch)
        before = footprint
        expect(settle(by: branch_settler).error).to eq(error_for(:not_authorized))
        expect(footprint).to eq(before)
      end

      it "refuses a branch-less account (business-wide settlers and the holder only)" do
        expect(account.branch).to be_nil
        expect(settle(by: branch_settler).error).to eq(error_for(:not_authorized))
      end

      it "allows the settler's own branch-less account" do
        own = create(:custody_account, business: business, user: branch_settler)
        expect(settle(by: branch_settler, account_id: own.id)).to be_ok
      end
    end
  end

  describe "atomicity" do
    it "rolls everything back when a write fails part-way" do
      calls = 0
      allow_any_instance_of(RemainingDepositBalance).to receive(:update!).and_wrap_original do |m, *args|
        calls += 1
        raise ActiveRecord::RecordInvalid, m.receiver if calls == 3

        m.call(*args)
      end
      before = footprint
      expect(settle).not_to be_ok
      expect(footprint).to eq(before)
      expect([ rdb1, rdb2, rdb3 ].map { |r| r.reload.status }.uniq).to eq([ "open" ])
    end

    it "rolls everything back when the bulk audit entry cannot be written" do
      allow(AuditLog).to receive(:create!).and_wrap_original do |m, **attrs|
        raise ActiveRecord::StatementInvalid, "boom" if attrs[:action] == "bulk_shortage_settlement"

        m.call(**attrs)
      end
      before = footprint
      result = settle
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.bulk_settle.audit_failed"))
      expect(footprint).to eq(before)
    end
  end
end
