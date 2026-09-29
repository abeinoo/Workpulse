FactoryBot.define do
  factory :job_title do
    business
    sequence(:name) { |n| "Job Title #{n}" }
    active { true }
  end
end
