# Gives a product a gallery image (ProductImage, the product's image store).
# Without position it is appended (the first one is the primary image).
module ProductImageHelpers
  TEST_IMAGE = Rails.root.join("spec/fixtures/files/test_image.png")

  def attach_product_image!(product, blob = nil, position: nil, filename: "a.png")
    file = blob || { io: File.open(TEST_IMAGE), filename: filename, content_type: "image/png" }
    position ||= (product.images.maximum(:position) || 0) + 1
    ProductImage.create!(product: product, position: position, file: file).tap { product.association(:images).reset }
  end

  def staged_image_blob(business:, filename: "staged.png")
    ActiveStorage::Blob.create_and_upload!(io: File.open(TEST_IMAGE), filename: filename, content_type: "image/png",
                                           metadata: { "staged_for_business_id" => business.id })
  end
end

RSpec.configure { |config| config.include ProductImageHelpers }
