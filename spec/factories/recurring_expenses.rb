FactoryBot.define do
  factory :recurring_expense do
    business { association :business }
    expense_category { association :expense_category, business: business }
    branch { nil }
    amount { 100 }
    frequency { "monthly" }
    start_date { Date.current }
    next_run_on { Date.current }
    active { true }
  end
end
