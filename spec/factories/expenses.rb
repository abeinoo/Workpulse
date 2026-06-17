FactoryBot.define do
  factory :expense do
    business { association :business }
    expense_category { association :expense_category, business: business }
    branch { nil }
    amount { 100 }
    expense_date { Date.current }
    sequence(:reference_number) { |n| "EXP-#{format('%06d', n)}" }
    notes { "Test expense" }
    status { "draft" }

    trait :pending do
      status { "pending_approval" }
    end

    trait :approved do
      status { "approved" }
    end

    trait :rejected do
      status { "rejected" }
    end

  end
end
