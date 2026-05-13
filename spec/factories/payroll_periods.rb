FactoryBot.define do
  factory :payroll_period do
    association :business
    branch       { nil }
    period_year  { Date.current.year }
    period_month { Date.current.month }
    working_days { 22 }
    status       { :draft }

    trait :for_branch do
      association :branch
    end

    trait :under_review do
      status { :under_review }
    end

    trait :branch_review_completed do
      status { :branch_review_completed }
    end

    trait :finalized do
      status { :finalized }
    end

    trait :paid do
      status { :paid }
    end

    trait :last_month do
      period_year  { Date.current.prev_month.year }
      period_month { Date.current.prev_month.month }
    end
  end
end
