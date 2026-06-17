FactoryBot.define do
  factory :branch_revenue do
    business { association :business }
    branch { association :branch, business: business }
    period_month { Date.current.beginning_of_month }
    amount { 1000 }
  end
end
