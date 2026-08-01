FactoryBot.define do
  factory :pos_import do
    association :business
    imported_by { association :user, business: business }
    file_name { "pos_export.xlsx" }
    status { "pending" }
  end
end
