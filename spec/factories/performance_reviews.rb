FactoryBot.define do
  factory :performance_review do
    association :business
    # Same-business defaults: SEC-P3-1 rejects references to another business.
    # Cross-business scenarios must pass the foreign records explicitly.
    department { association :department, business: business }
    employee   { association :user, business: business }
    reviewer   { association :user, business: business }
    review_year  { Date.current.year }
    review_month { Date.current.month }
    status       { "draft" }
  end
end
