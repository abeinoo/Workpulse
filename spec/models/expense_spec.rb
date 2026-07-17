require "rails_helper"

RSpec.describe Expense, type: :model do
  describe "payment_source" do
    it "syncs to employee_custody when paid from balance" do
      expense = create(:expense, deduct_from_balance: true)
      expect(expense.payment_source).to eq("employee_custody")
      expect(expense).to be_employee_custody_funded
    end

    it "syncs to unpaid when not paid from balance" do
      expense = create(:expense, deduct_from_balance: false)
      expect(expense.payment_source).to eq("unpaid")
      expect(expense).not_to be_employee_custody_funded
    end
  end

  describe "#settlement_total" do
    it "is the expense amount" do
      expense = create(:expense, amount: 250)
      expect(expense.settlement_total).to eq(250)
    end
  end
end
