require "rails_helper"

# Milestone 2 — Finance & Sales Expenses, M3: Payroll::Approver and
# Payroll::Reopener reach Finance only through the Payroll-defined
# Payroll::FinalizationEffects contract, inside their own transactions.
# End-to-end behaviour (expense created / voided / re-created, rollback) stays
# pinned by insurance_expense_refresh_spec, insurance_expense_category_spec,
# the finance_sales characterization and finalization_effects_spec.
RSpec.describe "Payroll finalization effects routing (M3)" do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business) }
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, status: "branch_review_completed")
  end

  # A recording handler that also notes how deep the transaction stack was.
  let(:handler) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def period_finalized(period:, actor:)
        @calls << [ :period_finalized, period, actor, ActiveRecord::Base.connection.open_transactions ]
      end

      def period_reopened(period:, actor:, reason:)
        @calls << [ :period_reopened, period, actor, reason, ActiveRecord::Base.connection.open_transactions ]
      end
    end.new
  end

  def with_handler(replacement)
    original = Payroll::FinalizationEffects.instance_variable_get(:@handler)
    Payroll::FinalizationEffects.instance_variable_set(:@handler, replacement)
    yield
  ensure
    Payroll::FinalizationEffects.instance_variable_set(:@handler, original)
  end

  def advance = Payroll::Approver.advance(period: period.reload, by: owner)
  def reopen  = Payroll::Reopener.call(period: period.reload, by: owner, reason: "Correct insurance")

  it "finalization calls period_finalized through the contract, inside the Approver transaction" do
    allow(Payroll::InsuranceExpenseGenerator).to receive(:call)
    outer = ActiveRecord::Base.connection.open_transactions

    with_handler(handler) { expect(advance).to be_success }

    expect(handler.calls.size).to eq(1)
    operation, called_period, actor, depth = handler.calls.first
    expect([ operation, called_period, actor ]).to eq([ :period_finalized, period, owner ])
    expect(depth).to be > outer
    expect(Payroll::InsuranceExpenseGenerator).not_to have_received(:call)
  end

  it "the paid transition triggers no effect" do
    period.update_columns(status: "finalized")

    with_handler(handler) { expect(advance).to be_success }

    expect(period.reload.status).to eq("paid")
    expect(handler.calls).to be_empty
  end

  it "reopening a finalized period calls period_reopened with the reason, inside the Reopener transaction" do
    period.update_columns(status: "finalized")
    allow(Payroll::InsuranceExpenseGenerator).to receive(:void_for)
    outer = ActiveRecord::Base.connection.open_transactions

    with_handler(handler) { expect(reopen).to be_success }

    operation, called_period, actor, reason, depth = handler.calls.sole
    expect([ operation, called_period, actor, reason ]).to eq([ :period_reopened, period, owner, "Correct insurance" ])
    expect(depth).to be > outer
    expect(Payroll::InsuranceExpenseGenerator).not_to have_received(:void_for)
  end

  it "reopening a paid period back to finalized triggers no effect" do
    period.update_columns(status: "paid")

    with_handler(handler) { expect(reopen).to be_success }

    expect(period.reload.status).to eq("finalized")
    expect(handler.calls).to be_empty
  end

  describe "a failing handler rolls the caller back with the same error result" do
    let(:failing) do
      double("failing handler").tap do |double|
        allow(double).to receive(:period_finalized).and_raise(ActiveRecord::RecordInvalid.new(Expense.new))
        allow(double).to receive(:period_reopened).and_raise(StandardError, "effect failed")
      end
    end

    it "Approver: not finalized, no audit row, error result" do
      result = with_handler(failing) { advance }

      expect(result).not_to be_success
      expect(period.reload.status).to eq("branch_review_completed")
      expect(PayrollAuditLog.where(payroll_period: period, action_type: "finalized")).to be_empty
    end

    it "Reopener: still finalized, no audit row, error message from the effect" do
      period.update_columns(status: "finalized")

      result = with_handler(failing) { reopen }

      expect(result).to have_attributes(success?: false, error: "effect failed")
      expect(period.reload.status).to eq("finalized")
      expect(PayrollAuditLog.where(payroll_period: period, action_type: "reopened")).to be_empty
    end
  end
end
