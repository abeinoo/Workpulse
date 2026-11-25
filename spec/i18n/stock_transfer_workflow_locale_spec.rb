require "rails_helper"

# The Stock Transfer workflow strings exist in BOTH languages, with the same
# interpolation variables (Arabic plural forms may add keys).
RSpec.describe "stock_transfer_workflow locale files" do
  def pairs(hash, prefix = nil)
    hash.flat_map do |key, value|
      path = [ prefix, key ].compact.join(".")
      value.is_a?(Hash) ? pairs(value, path) : [ [ path, value ] ]
    end
  end

  def plural_keys = %w[zero one two few many other]
  def flatten(locale) = pairs(YAML.load_file(Rails.root.join("config/locales/stock_transfer_workflow.#{locale}.yml"))[locale]).to_h
  def base(key) = plural_keys.include?(key.split(".").last) ? key.sub(/\.[a-z]+\z/, "") : key

  let(:en) { flatten("en") }
  let(:ar) { flatten("ar") }

  it "has every English key in Arabic and no Arabic-only key" do
    expect(en.keys.map { base(_1) }.uniq - ar.keys.map { base(_1) }.uniq).to be_empty
    expect(ar.keys.map { base(_1) }.uniq - en.keys.map { base(_1) }.uniq).to be_empty
  end

  it "uses the same interpolation variables in both languages" do
    vars = ->(text) { text.to_s.scan(/%\{(\w+)\}/).flatten.to_set }
    mismatched = en.filter_map do |key, text|
      next if plural_keys.include?(key.split(".").last) # Arabic forms may spell out the count
      key unless ar.key?(key) && vars.call(text) == vars.call(ar[key])
    end
    expect(mismatched).to be_empty
  end
end
