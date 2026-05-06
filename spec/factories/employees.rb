FactoryBot.define do
  factory :employee do
    sequence(:phone_number)    { |n| "+9665#{n.to_s.rjust(8, '0')}" }
    sequence(:employee_number) { |n| "EMP-#{n.to_s.rjust(4, '0')}" }
    sequence(:email)           { |n| "employee#{n}@example.com" }
    full_name                  { Faker::Name.name }
    department                 { Faker::Commerce.department }
    job_title                  { Faker::Job.title }
    hire_date                  { Faker::Date.backward(days: 365) }
    status                     { :active }
  end
end
