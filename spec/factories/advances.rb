FactoryBot.define do
  factory :advance do
    transient do
      business { create(:business) }
    end

    user             { create(:user, business: business) }
    total_amount     { 1_000.0 }
    remaining_amount { 1_000.0 }
    status           { :active }
    issued_at        { Date.current }

    after(:build) do |advance, evaluator|
      if advance.employee_request.nil?
        advance.employee_request = create(
          :employee_request, :salary_advance, :approved,
          user: advance.user
        )
      end
    end

    trait :partially_repaid do
      remaining_amount { 500.0 }
    end

    trait :fully_repaid do
      remaining_amount { 0.0 }
      status           { :fully_repaid }
    end
  end
end
