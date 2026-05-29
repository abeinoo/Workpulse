FactoryBot.define do
  factory :employee_request do
    transient do
      business { create(:business) }
    end

    user               { create(:user,   business: business) }
    request_type       { :late_permission }
    requested_for_date { Date.current + 1.day }
    reason             { Faker::Lorem.sentence }
    status             { :pending }
    duration_minutes   { 30 }

    trait :salary_advance do
      request_type { :salary_advance }
      amount       { 1_000.0 }
      reason       { "Emergency medical expense" }
    end

    trait :late_permission do
      request_type     { :late_permission }
      reason           { "Medical appointment in the morning" }
      duration_minutes { 30 }
    end

    trait :early_leave do
      request_type     { :early_leave }
      reason           { "Family obligation requires early departure" }
      duration_minutes { 30 }
    end

    trait :punch_correction do
      request_type     { :punch_correction }
      correction_type  { :missing_check_out }
      proposed_time    { "17:00" }
      duration_minutes { nil }
      reason           { "Forgot to clock out" }
    end

    trait :pending do
      status { :pending }
    end

    trait :approved do
      status      { :approved }
      reviewed_at { Time.current }
    end

    trait :rejected do
      status      { :rejected }
      reviewed_at { Time.current }
    end
  end
end
