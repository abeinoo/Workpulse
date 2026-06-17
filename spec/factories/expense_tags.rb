FactoryBot.define do
  factory :expense_tag do
    business { association :business }
    sequence(:name) { |n| "Tag #{n}" }
    active { true }
  end
end
