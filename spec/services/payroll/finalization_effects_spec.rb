require "rails_helper"

# Milestone 2 — Finance & Sales Expenses, M2: the Attendance & Payroll
# contract Payroll::FinalizationEffects and its Finance & Sales
# implementation Finance::PayrollFinalizationEffects (M2; callers routed in
# M3). Since M4 the expense lives in Finance::PayrollInsuranceExpense and
# Payroll passes the employer insurance cost as data
# (Payroll::EmployerInsuranceCost).
RSpec.describe Payroll::FinalizationEffects do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business) }
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, status: "finalized")
  end

  before do
    create(:payroll_entry, payroll_period: period, user: create(:user, business: business),
                           insured: true, employer_insurance_amount: 100)
  end

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  def active_expenses = Expense.where(source_payroll_period: period, voided_at: nil)

  def cost = Payroll::EmployerInsuranceCost.for(period)

  def finalized!
    described_class.period_finalized(period: period, actor: owner,
                                     employer_insurance_total: cost.total,
                                     employer_insurance_by_branch: cost.by_branch)
  end

  describe "registration" do
    it "has the Finance & Sales implementation registered at boot" do
      expect(described_class.handler).to equal(Finance::PayrollFinalizationEffects)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      incomplete = Module.new { def self.period_finalized(period:, actor:) = nil }

      expect { described_class.register(incomplete) }.to raise_error(ArgumentError, /period_reopened/)
      expect(described_class.handler).to equal(Finance::PayrollFinalizationEffects)
    end

    it "raises NotRegistered instead of silently skipping when no handler is registered" do
      with_handler(nil) do
        expect { finalized! }.to raise_error(described_class::NotRegistered)
      end
    end
  end

  describe "dispatch" do
    let(:handler) { double("handler", period_finalized: :finalized_result, period_reopened: :reopened_result) }

    it "passes each operation to the handler with its arguments and returns its result" do
      with_handler(handler) do
        expect(finalized!).to eq(:finalized_result)
        expect(described_class.period_reopened(period: period, actor: owner, reason: "Fix")).to eq(:reopened_result)
      end

      expect(handler).to have_received(:period_finalized)
        .with(period: period, actor: owner, employer_insurance_total: 100, employer_insurance_by_branch: { branch.id => 100 })
      expect(handler).to have_received(:period_reopened).with(period: period, actor: owner, reason: "Fix")
    end

    it "propagates a handler error to the caller (so the caller's transaction rolls back)" do
      allow(handler).to receive(:period_finalized).and_raise(ActiveRecord::RecordInvalid.new(Expense.new))

      with_handler(handler) do
        expect { finalized! }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe "Finance::PayrollFinalizationEffects (implementation)" do
    it "hands the payload to Finance::PayrollInsuranceExpense" do
      allow(Finance::PayrollInsuranceExpense).to receive(:record).and_call_original
      allow(Finance::PayrollInsuranceExpense).to receive(:void_for).and_call_original

      finalized!
      described_class.period_reopened(period: period, actor: owner, reason: "Fix")

      expect(Finance::PayrollInsuranceExpense).to have_received(:record)
        .with(period: period, actor: owner, total: 100, by_branch: { branch.id => 100 })
      expect(Finance::PayrollInsuranceExpense).to have_received(:void_for).with(period: period, actor: owner, reason: "Fix")
    end

    it "creates the insurance expense on finalization, idempotently, and voids it on reopen" do
      result = finalized!
      expect(result).to be_ok
      expect(active_expenses.sole).to have_attributes(amount: 100, status: "approved", source_payroll_period_id: period.id)

      expect { finalized! }.not_to change(Expense, :count)

      described_class.period_reopened(period: period, actor: owner, reason: "Fix")
      expect(active_expenses).to be_empty
      expect(Expense.find_by!(source_payroll_period: period)).to have_attributes(status: "cancelled")
    end

    it "writes inside the caller's transaction (a rollback leaves no expense)" do
      ActiveRecord::Base.transaction do
        finalized!
        expect(active_expenses.count).to eq(1)
        raise ActiveRecord::Rollback
      end

      expect(Expense.where(source_payroll_period: period)).to be_empty
    end
  end

  it "keeps the Payroll contract free of Finance & Sales references" do
    source = File.read(Rails.root.join("app/services/payroll/finalization_effects.rb"))
    code   = source.each_line.reject { |line| line.lstrip.start_with?("#") }.join

    expect(code).not_to match(/\bFinance::|\bExpense\w*\b/)
  end
end
