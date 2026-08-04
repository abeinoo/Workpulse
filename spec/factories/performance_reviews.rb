FactoryBot.define do
  factory :performance_review do
    association :business
    association :department
    association :employee, factory: :user
    association :reviewer, factory: :user
    review_year  { Date.current.year }
    review_month { Date.current.month }
    status       { "draft" }
  end
end
