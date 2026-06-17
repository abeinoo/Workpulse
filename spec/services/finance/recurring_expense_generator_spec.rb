require "rails_helper"

RSpec.describe Finance::RecurringExpenseGenerator, type: :model do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:branch)   { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }

  def recurring(attrs = {})
    create(:recurring_expense, { business: business, expense_category: category,
                                 branch: branch, amount: 500, frequency: "monthly",
                                 start_date: Date.current, next_run_on: Date.current,
                                 created_by: owner }.merge(attrs))
  end

  describe "#call (due template)" do
    it "creates a PENDING expense, never paid, linked to the source, and advances the schedule" do
      rec = recurring
      result = described_class.new(rec).call

      expect(result.ok?).to be true
      expense = result.expense
      expect(expense.status).to eq("pending_approval")
      expect(expense.source_recurring_expense_id).to eq(rec.id)
      expect(expense.branch_id).to eq(branch.id)
      expect(expense.amount).to eq(500)
      expect(expense.reference_number).to match(/\AEXP-\d{6}\z/)

      rec.reload
      expect(rec.next_run_on).to eq(Date.current + 1.month)
      expect(rec.last_generated_on).to eq(Date.current)
    end

    it "writes an audit entry attributed to the template creator" do
      rec = recurring
      expect { described_class.new(rec).call }
        .to change { AuditLog.where(action: "recurring_generate").count }.by(1)
    end

    it "reproduces shared allocations that reconcile to the amount" do
      b2  = create(:branch, business: business)
      rec = recurring(branch: nil)
      rec.recurring_expense_allocations.create!(branch: branch, allocation_percentage: 60)
      rec.recurring_expense_allocations.create!(branch: b2, allocation_percentage: 40)

      expense = described_class.new(rec).call.expense
      expect(expense).to be_is_shared
      expect(expense.expense_allocations.sum(&:allocated_amount)).to eq(500)
      expect(expense.expense_allocations.map(&:allocated_amount)).to eq([ 300, 200 ])
    end
  end

  describe "schedule guards" do
    it "skips when not due (future next_run_on) without force" do
      rec = recurring(next_run_on: Date.current + 10)
      result = described_class.new(rec).call
      expect(result.ok?).to be false
      expect(result.reason).to eq(:not_due)
    end

    it "force generates even when not yet due" do
      rec = recurring(next_run_on: Date.current + 10)
      expect(described_class.new(rec, force: true).call.ok?).to be true
    end

    it "skips inactive templates" do
      rec = recurring(active: false)
      expect(described_class.new(rec, force: true).call.reason).to eq(:inactive)
    end

    it "skips ended templates" do
      rec = recurring(start_date: Date.current - 60, end_date: Date.current - 1)
      expect(described_class.new(rec, force: true).call.reason).to eq(:ended)
    end
  end

  describe "duplicate prevention (DB unique index + lock path)" do
    it "returns :already_generated instead of creating a second expense for the same date" do
      rec = recurring
      first = described_class.new(rec).call
      expect(first.ok?).to be true

      # Force a generation for the SAME date the first one used.
      used_date = first.expense.expense_date
      second = described_class.new(rec, on: used_date, force: true).call

      expect(second.ok?).to be false
      expect(second.reason).to eq(:already_generated)
      expect(business.expenses.where(source_recurring_expense_id: rec.id, expense_date: used_date).count).to eq(1)
    end

    it "is enforced at the database level (partial unique index)" do
      rec = recurring
      business.expenses.create!(expense_category: category, amount: 1, expense_date: Date.current,
                                reference_number: "EXP-RAW1", status: "pending_approval",
                                source_recurring_expense: rec)
      expect {
        business.expenses.create!(expense_category: category, amount: 1, expense_date: Date.current,
                                  reference_number: "EXP-RAW2", status: "pending_approval",
                                  source_recurring_expense: rec)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
