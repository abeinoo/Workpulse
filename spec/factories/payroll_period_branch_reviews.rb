FactoryBot.define do
  factory :payroll_period_branch_review do
    association :payroll_period
    association :branch
    association :reviewer, factory: :user
    status { :pending }
  end
end
