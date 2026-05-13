FactoryBot.define do
  factory :business do
    sequence(:name) { |n| "#{Faker::Company.name} #{n}" }
    timezone                { "Asia/Riyadh" }
    working_days_per_month  { 22 }
    business_day_start_hour { 0 }
  end
end
