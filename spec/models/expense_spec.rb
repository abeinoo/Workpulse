require "rails_helper"

RSpec.describe Expense, type: :model do
  describe "payment_source" do
    it "syncs to employee_custody when paid from balance" do
      expense = create(:expense, deduct_from_balance: true)
      expect(expense.payment_source).to eq("employee_custody")
      expect(expense).to be_employee_custody_funded
    end

    it "syncs to not_linked_to_balance for a direct expense not paid from balance" do
      expense = create(:expense, payment_type: "direct", deduct_from_balance: false)
      expect(expense.payment_source).to eq("not_linked_to_balance")
      expect(expense).not_to be_employee_custody_funded
    end

    it "syncs to unpaid for an installment expense (never paid from balance)" do
      expense = create(:expense, payment_type: "installment")
      expect(expense.payment_source).to eq("unpaid")
      expect(expense).not_to be_employee_custody_funded
    end
  end

  describe "payment_type vs deduct_from_balance (independent axes, enforced at the model)" do
    it "an installment expense can never carry deduct_from_balance: true, even if explicitly requested" do
      expense = create(:expense, payment_type: "installment", deduct_from_balance: true)
      expect(expense.deduct_from_balance).to eq(false)
      expect(expense.payment_source).to eq("unpaid")
    end

    it "forces it back to false on update too, not just on create" do
      expense = create(:expense, payment_type: "installment", deduct_from_balance: false)
      expense.update!(deduct_from_balance: true)
      expect(expense.reload.deduct_from_balance).to eq(false)
    end

    it "a direct expense may freely opt into deduct_from_balance: true" do
      expense = create(:expense, payment_type: "direct", deduct_from_balance: true)
      expect(expense.deduct_from_balance).to eq(true)
      expect(expense.payment_source).to eq("employee_custody")
    end

    it "a direct expense defaults to deduct_from_balance: false (not auto-checked)" do
      expense = create(:expense, payment_type: "direct")
      expect(expense.deduct_from_balance).to eq(false)
    end
  end

  describe "#settlement_total" do
    it "is the expense amount" do
      expense = create(:expense, amount: 250)
      expect(expense.settlement_total).to eq(250)
    end
  end
end
