FactoryBot.define do
  factory :expense_type do
    business { association :business }
    expense_category { association :expense_category, business: business }
    sequence(:name) { |n| "Type #{n}" }
    active { true }
  end
end
