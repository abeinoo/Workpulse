FactoryBot.define do
  factory :biometric_device do
    association :business
    sequence(:name)  { |n| "Device #{n}" }
    sequence(:token) { |n| "device-token-#{n}" }
    active { true }
  end
end
