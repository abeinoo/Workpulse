require "rails_helper"

# BUG-003, the production COMMIT path. Inside the transactional fixture a
# service transaction is only a savepoint, so the original bug showed up there
# as an exception; in production the COMMIT after a failed audit insert
# silently became a ROLLBACK while the service reported success. These
# examples run without the fixture and read the state back after the real
# COMMIT, with a real PostgreSQL failure of the audit insert
# (AuditFailureHelpers#fail_audit_writes!).
RSpec.describe "AuditLoggable on the real COMMIT path" do
  include_context "non-transactional database"

  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:actor)     { create(:user, business: business) }
  let(:statement) { create(:bank_statement, :pending, business: business, branch: branch) }

  def line!(status:)
    BankStatementTransaction.create!(bank_statement: statement, business: business, amount: 300,
                                     transaction_date: Date.current, raw_data: {}, status: status)
  end

  def committed(record) = record.class.uncached { record.class.find(record.id) }

  it "fail-open, audit as the last statement: the reported success is really committed" do
    line = line!(status: "unexpected")
    statement.update_columns(unmatched_rows: 1)
    fail_audit_writes!(:ignored)

    result = Finance::BankStatements::Ignorer.call(line.id, actor: actor, reason: "Bank fee")

    expect(result).to be_ok
    expect(ActiveRecord::Base.connection.transaction_open?).to be false
    expect(committed(line)).to have_attributes(status: "ignored", ignored_reason: "Bank fee")
    expect(committed(statement).unmatched_rows).to eq(0)
    expect(AuditLog.where(auditable: line)).to be_empty
  end

  it "fail-closed: a reported failure leaves nothing committed" do
    dr = DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                     opened_at: 1.hour.ago, business_date: Date.current)
    cash = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
    deposit = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash, deposited_by: actor,
                                  amount: 300, deposited_at: Time.current)
    line = line!(status: "verified")
    DepositMatch.create_for!(till_deposit: deposit, bank_statement_transaction: line, matched_by: actor)
    statement.update_columns(matched_rows: 1, unmatched_rows: 0)
    fail_audit_writes!(:manual_unmatch)

    result = Finance::BankStatements::Unmatcher.call(line.id, actor: actor, notes: "wrong deposit")

    expect(result).not_to be_ok
    expect(committed(line).status).to eq("verified")
    expect(DepositMatch.where(bank_statement_transaction_id: line.id).count).to eq(1)
    expect(committed(statement).matched_rows).to eq(1)
  end
end
