require "rails_helper"

# R3.2 G3: Attendance & Payroll's answer to Employee::PayrollDateProtection
# (OD-10, OD-12, OD-13, §19.14). The two-connection race behaviour is proven
# with the change service (G5) and the Submit for Review lock (G4); here: which
# periods are protected, and that the lock path locks every overlapping period
# without a status filter, after the business's payroll-status lock.
RSpec.describe Payroll::RequirementDateProtection do
  let(:business) { create(:business) }
  let(:other_business) { create(:business) }

  def period(month, status, biz = business, year: 2026)
    create(:payroll_period, business: biz, period_year: year, period_month: month, status: status)
  end

  def lock_answer(from, through)
    ActiveRecord::Base.transaction(requires_new: true) do
      described_class.lock_protected_range(business_id: business.id, from: from, through: through)
    end
  end

  def ranges(from, through) = described_class.protected_ranges(business_id: business.id, from: from, through: through)

  { "under_review" => :in_review, "branch_review_completed" => :in_review,
    "finalized" => :finalized, "paid" => :finalized }.each do |status, stage|
    it "reports a #{status} period as #{stage}" do
      period(9, status)
      answer = lock_answer(Date.new(2026, 9, 10), Date.new(2026, 9, 12))
      expect(answer).to have_attributes(starts_on: Date.new(2026, 9, 1), ends_on: Date.new(2026, 9, 30), stage: stage)
    end
  end

  it "does not protect a draft period or a month without a period" do
    period(9, "draft")
    expect(lock_answer(Date.new(2026, 8, 1), Date.new(2026, 10, 31))).to be_nil
    expect(ranges(Date.new(2026, 8, 1), Date.new(2026, 10, 31))).to eq([])
  end

  it "counts a period that only partly overlaps the dates" do
    period(9, "finalized")
    expect(lock_answer(Date.new(2026, 9, 30), Date.new(2026, 10, 5))).to have_attributes(stage: :finalized)
    expect(lock_answer(Date.new(2026, 10, 1), Date.new(2026, 10, 5))).to be_nil
  end

  it "returns the earliest protected period when several overlap, and lists them all for the warning" do
    period(11, "under_review")
    period(10, "draft")
    period(9, "paid")
    expect(lock_answer(Date.new(2026, 9, 1), Date.new(2026, 11, 30))).to have_attributes(starts_on: Date.new(2026, 9, 1))
    expect(ranges(Date.new(2026, 9, 1), Date.new(2026, 11, 30)).map(&:starts_on))
      .to eq([ Date.new(2026, 9, 1), Date.new(2026, 11, 1) ])
  end

  it "spans a year boundary" do
    period(12, "under_review", year: 2025)
    expect(lock_answer(Date.new(2025, 12, 20), Date.new(2026, 1, 5))).to have_attributes(starts_on: Date.new(2025, 12, 1))
  end

  it "protects a period in which the employee has no payroll entry (every period of the business)" do
    period(9, "under_review")
    expect(PayrollEntry.count).to eq(0)
    expect(lock_answer(Date.new(2026, 9, 1), Date.new(2026, 9, 1))).not_to be_nil
  end

  it "ignores another business's periods" do
    period(9, "finalized", other_business)
    expect(lock_answer(Date.new(2026, 9, 1), Date.new(2026, 9, 30))).to be_nil
    expect(ranges(Date.new(2026, 9, 1), Date.new(2026, 9, 30))).to eq([])
  end

  it "answers nothing for an empty range" do
    period(9, "finalized")
    expect(lock_answer(Date.new(2026, 9, 2), Date.new(2026, 9, 1))).to be_nil
    expect(ranges(Date.new(2026, 9, 2), Date.new(2026, 9, 1))).to eq([])
  end

  describe "locking (§19.14)" do
    def statements
      captured = []
      callback = ->(*, payload) { captured << payload[:sql] }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      captured
    end

    it "takes the business's payroll-status lock in shared mode before locking the period rows" do
      period(9, "draft")
      sql = statements { lock_answer(Date.new(2026, 9, 1), Date.new(2026, 9, 30)) }

      lock_index = sql.index { |s| s.include?("pg_advisory_xact_lock_shared(#{Payroll::StatusLock::NAMESPACE}, #{business.id})") }
      rows_index = sql.index { |s| s.include?("FROM \"payroll_periods\"") && s.include?("FOR SHARE") }
      expect(lock_index).not_to be_nil
      expect(rows_index).not_to be_nil
      expect(lock_index).to be < rows_index
    end

    it "locks every overlapping period with no status filter, in id order" do
      sql = statements { lock_answer(Date.new(2026, 9, 1), Date.new(2026, 9, 30)) }
      row_lock = sql.find { |s| s.include?("FOR SHARE") }
      expect(row_lock).not_to match(/status/i)
      expect(row_lock).to match(/ORDER BY "payroll_periods"\."id" ASC/)
    end

    it "holds the shared payroll-status lock for the rest of the transaction" do
      ActiveRecord::Base.transaction(requires_new: true) do
        described_class.lock_protected_range(business_id: business.id, from: Date.new(2026, 9, 1), through: Date.new(2026, 9, 30))
        held = ActiveRecord::Base.connection.select_rows(<<~SQL)
          SELECT classid, objid, mode FROM pg_locks
          WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted
        SQL
        expect(held.map { |classid, objid, mode| [ classid.to_i, objid.to_i, mode ] })
          .to include([ Payroll::StatusLock::NAMESPACE, business.id, "ShareLock" ])
      end
    end

    it "takes no lock for the read-only warning lookup" do
      period(9, "finalized")
      sql = statements { ranges(Date.new(2026, 9, 1), Date.new(2026, 9, 30)) }
      expect(sql.join("\n")).not_to match(/FOR SHARE|FOR UPDATE|pg_advisory/)
    end

    it "refuses to take the payroll-status lock outside a transaction" do
      allow(PayrollPeriod.connection).to receive(:transaction_open?).and_return(false)
      expect { Payroll::StatusLock.shared!(business_id: business.id) }.to raise_error(Payroll::StatusLock::OutsideTransaction)
      expect { Payroll::StatusLock.exclusive!(business_id: business.id) }.to raise_error(Payroll::StatusLock::OutsideTransaction)
    end
  end
end
