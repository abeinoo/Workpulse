FactoryBot.define do
  factory :user do
    association :employee
    password              { "password123" }
    password_confirmation { "password123" }
    role                  { :employee }

    trait :admin do
      employee { nil }
      role     { :admin }
    end
  end
end
