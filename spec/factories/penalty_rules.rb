FactoryBot.define do
  factory :penalty_rule do
    association :shift, factory: [:shift, :fixed_time]
    rule_type         { :late_arrival }
    deduction_type    { :fixed_amount }
    threshold_minutes { 15 }
    deduction_value   { 50.0 }

    trait :late_arrival do
      rule_type { :late_arrival }
    end

    trait :early_leave do
      rule_type { :early_leave }
    end

    trait :fixed_amount do
      deduction_type  { :fixed_amount }
      deduction_value { 50.0 }
    end

    trait :percentage_of_daily do
      deduction_type  { :percentage_of_daily }
      deduction_value { 10.0 }
    end
  end
end
