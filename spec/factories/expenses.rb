FactoryBot.define do
  factory :expense do
    business { association :business }
    expense_category { association :expense_category, business: business }
    branch { association :branch, business: business }
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

    trait :cancelled do
      status { "cancelled" }
    end

    trait :system_generated do
      source_recurring_expense { association :recurring_expense, business: business }
    end
  end
end
