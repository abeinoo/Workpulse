FactoryBot.define do
  factory :pos_import_ignored_row do
    association :business
    pos_import { association :pos_import, business: business }
    ignored_by { association :user, business: business }
    sequence(:row_number) { |n| n }
    reason { "Corrupted export row" }
  end
end
