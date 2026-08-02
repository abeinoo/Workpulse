FactoryBot.define do
  factory :employee_insurance_profile do
    business { user&.business || association(:business) }
    association :user
    created_by { association :user, business: business }
    insured { true }
    employee_contribution_amount { 450.0 }
    employer_contribution_amount { 1_250.0 }
    insurance_start_date { 1.year.ago.to_date }
    insurance_end_date { nil }
    insurance_number { nil }
    notes { nil }

    trait :not_insured do
      insured { false }
      employee_contribution_amount { 0 }
      employer_contribution_amount { 0 }
    end
  end
end
