FactoryBot.define do
  factory :branch do
    association :business
    sequence(:name) { |n| "Branch #{n}" }
    address             { Faker::Address.street_address }
    active              { true }
    geolocation_enabled { false }

    # Branch with GPS enforcement — coordinates are in central Riyadh
    trait :with_geolocation do
      geolocation_enabled { true }
      latitude            { 24.7136 }
      longitude           { 46.6753 }
      radius_meters       { 200 }
    end

    trait :inactive do
      active { false }
    end
  end
end
