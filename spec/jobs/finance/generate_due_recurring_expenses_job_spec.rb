require "rails_helper"

RSpec.describe Finance::GenerateDueRecurringExpensesJob, type: :job do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:branch)   { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }

  def recurring(attrs = {})
    create(:recurring_expense, { business: business, expense_category: category, branch: branch,
                                 amount: 50, frequency: "monthly", created_by: owner }.merge(attrs))
  end

  it "generates one expense for a template due today" do
    rec = recurring(start_date: Date.current, next_run_on: Date.current)
    expect { described_class.new.perform }
      .to change { rec.generated_expenses.count }.by(1)
  end

  it "catches up multiple missed periods in one pass" do
    rec = recurring(start_date: 2.months.ago.to_date, next_run_on: 2.months.ago.to_date)
    described_class.new.perform
    # this month + the two missed months = 3
    expect(rec.generated_expenses.count).to eq(3)
    expect(rec.reload.next_run_on).to be > Date.current
    expect(rec.generated_expenses.pluck(:status).uniq).to eq(%w[pending_approval])
  end

  it "ignores inactive and not-yet-due templates" do
    recurring(active: false, next_run_on: Date.current)
    recurring(next_run_on: Date.current + 20)
    expect { described_class.new.perform }
      .not_to change { business.expenses.count }
  end

  it "isolates failures — one bad template does not block others" do
    good = recurring(next_run_on: Date.current)
    bad  = recurring(next_run_on: Date.current)
    allow(Finance::RecurringExpenseGenerator).to receive(:new).and_call_original
    allow(Finance::RecurringExpenseGenerator).to receive(:new).with(bad).and_raise(StandardError, "boom")

    expect { described_class.new.perform }.not_to raise_error
    expect(good.generated_expenses.count).to eq(1)
  end
end
