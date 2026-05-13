FactoryBot.define do
  factory :user_branch do
    association :user
    association :branch
    active    { true }
    joined_at { 1.month.ago.to_date }

    trait :inactive do
      active { false }
    end
  end
end
