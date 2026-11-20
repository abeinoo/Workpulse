require "rails_helper"

# Phase 2: the product availability strings exist in BOTH languages, with the
# same interpolation variables (Arabic plural forms may add keys).
RSpec.describe "product_availability locale files" do
  def pairs(hash, prefix = nil)
    hash.flat_map do |key, value|
      path = [ prefix, key ].compact.join(".")
      value.is_a?(Hash) ? pairs(value, path) : [ [ path, value ] ]
    end
  end

  def flatten(hash) = pairs(hash).to_h

  PLURAL_KEYS = %w[zero one two few many other].freeze

  let(:en) { flatten(YAML.load_file(Rails.root.join("config/locales/product_availability.en.yml"))["en"]) }
  let(:ar) { flatten(YAML.load_file(Rails.root.join("config/locales/product_availability.ar.yml"))["ar"]) }

  def base(key) = PLURAL_KEYS.include?(key.split(".").last) ? key.sub(/\.[a-z]+\z/, "") : key

  it "has every English key in Arabic and no Arabic-only key" do
    expect(en.keys.map { base(_1) }.uniq - ar.keys.map { base(_1) }.uniq).to be_empty
    expect(ar.keys.map { base(_1) }.uniq - en.keys.map { base(_1) }.uniq).to be_empty
  end

  it "uses the same interpolation variables in both languages" do
    vars = ->(text) { text.to_s.scan(/%\{(\w+)\}/).flatten.to_set }
    mismatched = en.filter_map do |key, text|
      next if PLURAL_KEYS.include?(key.split(".").last) # Arabic forms may spell out the count
      key unless ar.key?(key) && vars.call(text) == vars.call(ar[key])
    end
    expect(mismatched).to be_empty
  end
end
