FactoryBot.define do
  factory :payroll_period_branch_review do
    association :payroll_period
    association :branch
    association :reviewer, factory: :user
    status { :pending }

    # The period's central review (floating employees): no branch, no reviewer yet.
    trait :central do
      branch   { nil }
      reviewer { nil }
    end
  end
end
