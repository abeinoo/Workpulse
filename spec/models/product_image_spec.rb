require "rails_helper"

RSpec.describe ProductImage, type: :model do
  let(:business) { create(:business) }
  let(:product)  { business.products.create!(name: "Argan Oil", sku: "AO-1", initial_cost_price: 1, average_cost_price: 1) }
  def png = { io: File.open(ProductImageHelpers::TEST_IMAGE), filename: "a.png", content_type: "image/png" }

  it "takes the product's business and needs a file and a positive position" do
    image = ProductImage.create!(product: product, position: 1, file: png)
    expect(image.business).to eq(business)
    expect(ProductImage.new(product: product, position: 1)).not_to be_valid
    expect(ProductImage.new(product: product, position: 0, file: png)).not_to be_valid
  end

  it "refuses a non-image file and another business" do
    text = { io: StringIO.new("hello"), filename: "a.txt", content_type: "text/plain" }
    expect(ProductImage.new(product: product, position: 1, file: text)).not_to be_valid
    expect(ProductImage.new(product: product, business: create(:business), position: 1, file: png)).not_to be_valid
  end

  it "the product's images are ordered by position; the first is the primary image" do
    second = ProductImage.create!(product: product, position: 2, file: png)
    first  = ProductImage.create!(product: product, position: 1, file: png)
    expect(product.images.reload).to eq([ first, second ])
    expect(product.reload.primary_image).to eq(first)
    expect(Product.with_primary_image.find(product.id).association(:primary_image)).to be_loaded
  end

  it "goes with its product when the product is deleted" do
    ProductImage.create!(product: product, position: 1, file: png)
    expect { product.destroy! }.to change(ProductImage, :count).by(-1)
  end
end
