FactoryBot.define do
  factory :department do
    association :business
    sequence(:name) { |n| "Department #{n}" }
    active { true }
  end
end
