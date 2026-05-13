FactoryBot.define do
  factory :user do
    association :business
    first_name            { Faker::Name.first_name }
    last_name             { Faker::Name.last_name }
    sequence(:email)      { |n| "user#{n}@example.com" }
    password              { "password123" }
    password_confirmation { "password123" }
    role                  { :employee }
    active                { true }

    trait :super_admin do
      role { :super_admin }
    end

    trait :branch_manager do
      role { :branch_manager }
    end

    trait :accountant do
      role { :accountant }
    end

    trait :employee do
      role { :employee }
    end

    # Has a phone number in addition to email
    trait :with_phone do
      sequence(:phone_number) { |n| "+966500#{n.to_s.rjust(6, '0')}" }
    end

    # Has only a phone number — no email address
    trait :phone_only do
      email { nil }
      sequence(:phone_number) { |n| "+966500#{n.to_s.rjust(6, '0')}" }
    end

    trait :inactive do
      active { false }
    end

    # Pre-created by admin; employee has not yet set a password
    trait :unregistered do
      password              { nil }
      password_confirmation { nil }
      after(:create) { |u| u.update_column(:encrypted_password, "") }
    end
  end
end
