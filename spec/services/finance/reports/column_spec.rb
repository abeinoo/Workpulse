require "rails_helper"

# Regression: Finance::Reports::Column used to be defined inside table.rb, so
# under lazy loading (test without CI, development) referencing Column before
# Table raised NameError — e.g. the laundry cost-summary CSV export. These
# checks hold in both lazy and eager mode, independent of example order.
RSpec.describe Finance::Reports::Column do
  it "is the constant Zeitwerk expects in its own file, so it autoloads without Table" do
    path = Rails.root.join("app/services/finance/reports/column.rb")

    expect(Rails.autoloaders.main.cpath_expected_at(path)).to eq("Finance::Reports::Column")
  end

  it "is defined in column.rb only (not also in table.rb)" do
    file, = Finance::Reports.const_source_location(:Column)

    expect(file).to eq(Rails.root.join("app/services/finance/reports/column.rb").to_s)
    expect(File.read(Rails.root.join("app/services/finance/reports/table.rb"))).not_to match(/^\s*Column\s*=/)
  end

  it "keeps its keyword-init Struct API" do
    column = described_class.new(key: :amount, label: "Amount", money: true)

    expect(described_class.members).to eq(%i[key label money])
    expect([ column.key, column.label, column.money ]).to eq([ :amount, "Amount", true ])
  end
end
