require "rails_helper"

RSpec.describe Finance::Dashboard::InsightsGenerator do
  def generate(**overrides)
    defaults = {
      by_category: {}, by_category_previous: {}, by_branch: {}, total_expenses: 0
    }
    described_class.new(**defaults.merge(overrides)).insights
  end

  it "returns nothing when there is no previous-period data to compare against" do
    insights = generate(by_category: { "Maintenance" => 1000 })
    expect(insights).to be_empty
  end

  it "flags a category change that crosses the threshold" do
    insights = generate(
      by_category: { "Maintenance" => 1220 },
      by_category_previous: { "Maintenance" => 1000 }
    )
    expect(insights.size).to eq(1)
    expect(insights.first.severity).to eq(:warning)
    expect(insights.first.title).to include("22%")
  end

  it "ignores a category change under the threshold" do
    insights = generate(
      by_category: { "Maintenance" => 1050 },
      by_category_previous: { "Maintenance" => 1000 }
    )
    expect(insights).to be_empty
  end

  it "flags a branch that dominates total expenses" do
    insights = generate(by_branch: { "Downtown" => 3400 }, total_expenses: 10_000)
    expect(insights.size).to eq(1)
    expect(insights.first.title).to include("34%")
  end

  it "flags a high payroll share of operating cost" do
    insights = generate(payroll_cost: 4600, operating_cost: 10_000)
    expect(insights.size).to eq(1)
    expect(insights.first.title).to include("46%")
  end

  it "stays silent when payroll share is below threshold" do
    insights = generate(payroll_cost: 2000, operating_cost: 10_000)
    expect(insights).to be_empty
  end

  it "caps the number of insights returned" do
    by_category = (1..10).index_with { 1500 }
    by_category_previous = (1..10).index_with { 1000 }
    insights = generate(by_category: by_category.transform_keys(&:to_s),
                         by_category_previous: by_category_previous.transform_keys(&:to_s))
    expect(insights.size).to eq(described_class::MAX_INSIGHTS)
  end
end
