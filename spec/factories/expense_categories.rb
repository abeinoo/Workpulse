FactoryBot.define do
  factory :expense_category do
    business { association :business }
    sequence(:name) { |n| "Category #{n}" }
    active { true }
  end
end
