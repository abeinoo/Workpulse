FactoryBot.define do
  factory :shift_template do
    transient do
      business { create(:business) }
    end

    association :created_by, factory: :user
    sequence(:name) { |n| "Template #{n}" }
    description     { "A reusable scheduling template" }
    active          { true }
    archived_at     { nil }

    after(:build) do |template, evaluator|
      template.business ||= evaluator.business
      template.created_by.business ||= evaluator.business
    end

    trait :archived do
      archived_at { 1.day.ago }
    end

    trait :with_entry do
      after(:create) do |template|
        create(:shift_template_entry, shift_template: template)
      end
    end
  end
end
