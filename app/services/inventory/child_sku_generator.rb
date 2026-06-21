module Inventory
  # Generates unique business-scoped SKUs for child products created by the
  # Parent/Child migration wizard.
  #
  # Guarantees uniqueness across the entire business by loading all existing SKUs
  # into a Set once, then tracking allocations within the wizard run before
  # anything is committed to the database.
  #
  # Usage (one instance per wizard run, shared across all children):
  #
  #   generator = Inventory::ChildSkuGenerator.new(business)
  #   sku = generator.generate(parent: parent_product, name: "Black", index: 0)
  #
  class ChildSkuGenerator
    def initialize(business)
      @business = business
      @reserved = Set.new(
        @business.products.pluck(:sku).map(&:downcase)
      )
    end

    # Returns a unique, business-scoped SKU string.
    # @param parent [Product]  the parent product
    # @param name   [String]   the child product's intended name (may be blank)
    # @param index  [Integer]  0-based position among siblings
    def generate(parent:, name: nil, index: 0)
      base      = derive_base(parent: parent, name: name, index: index)
      candidate = base
      suffix    = 1

      while @reserved.include?(candidate.downcase)
        candidate = "#{base}-#{suffix}"
        suffix   += 1
      end

      @reserved.add(candidate.downcase)
      candidate
    end

    private

    def derive_base(parent:, name:, index:)
      slug = name.to_s.strip
      return "#{parent.sku}-#{slug.gsub(/\s+/, '-').upcase}" if slug.present?
      "#{parent.sku}-#{index + 1}"
    end
  end
end
