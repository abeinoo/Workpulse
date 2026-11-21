require "rails_helper"

RSpec.describe Inventory::ProductGalleryUpdater do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:viewer)   { user_with_stock_permissions(business, :view_inventory) }
  let(:product)  { business.products.create!(name: "Argan Oil", sku: "AO-1", initial_cost_price: 1, average_cost_price: 1) }

  def upload(file = ProductImageHelpers::TEST_IMAGE, type: "image/png")
    Rack::Test::UploadedFile.new(file, type)
  end

  def stage!(actor = owner, file = upload)
    described_class.stage(actor: actor, file: file).tap { |result| expect(result).to be_ok }.signed_id
  end

  def apply(entries, actor: owner) = described_class.new(actor: actor, product_id: product.id, entries: entries).call
  def order = product.images.reload.map(&:id)

  describe ".stage" do
    it "stores a valid photo as an unattached blob of this business and returns a signed id" do
      result = described_class.stage(actor: owner, file: upload)
      blob = ActiveStorage::Blob.find_signed(result.signed_id, purpose: described_class::STAGE_PURPOSE)
      expect(blob.content_type).to eq("image/png")
      expect(blob.metadata["staged_for_business_id"]).to eq(business.id)
      expect(blob.attachments).to be_empty
      expect(ProductImage.count).to eq(0)
    end

    it "refuses a file that is not an image by its content (whatever it claims), and removes it" do
      text = Tempfile.new([ "fake", ".png" ]).tap { |f| f.write("not an image"); f.rewind }
      expect { expect(described_class.stage(actor: owner, file: upload(text.path)).error).to eq(:invalid_type) }
        .not_to change(ActiveStorage::Blob, :count)
    end

    it "refuses a file that is too large, and a user who may not edit products" do
      big = upload
      allow(big).to receive(:size).and_return(Attachable::DEFAULT_MAX_SIZE + 1)
      expect(described_class.stage(actor: owner, file: big).error).to eq(:too_large)
      expect(described_class.stage(actor: viewer, file: upload).error).to eq(:not_authorized)
      expect(described_class.stage(actor: owner, file: nil).error).to eq(:no_file)
    end
  end

  describe "#call" do
    it "adds several photos in one save, in the given order; the first is the primary image" do
      first, second, third = Array.new(3) { stage! }
      expect(apply([ "upload:#{first}", "upload:#{second}", "upload:#{third}" ])).to be_ok

      images = product.images.reload
      expect(images.map(&:position)).to eq([ 1, 2, 3 ])
      expect(product.reload.primary_image).to eq(images.first)
      expect(images.map { |i| i.file.blob.signed_id(purpose: described_class::STAGE_PURPOSE) }).to all(be_present)
    end

    it "reorders and chooses the primary image, persisting the positions" do
      a = attach_product_image!(product)
      b = attach_product_image!(product)
      c = attach_product_image!(product)

      expect(apply([ "image:#{c.id}", "image:#{a.id}", "image:#{b.id}" ])).to be_ok
      expect(order).to eq([ c.id, a.id, b.id ])
      expect(product.reload.primary_image).to eq(c)
      expect(product.images.map(&:position)).to eq([ 1, 2, 3 ])
    end

    it "removes the images left out and mixes kept images with new uploads" do
      a = attach_product_image!(product)
      b = attach_product_image!(product)
      signed = stage!

      expect(apply([ "upload:#{signed}", "image:#{b.id}" ])).to be_ok
      expect(ProductImage.exists?(a.id)).to be(false)
      expect(product.images.reload.map(&:id).last).to eq(b.id)
      expect(product.primary_image.file.blob.filename.to_s).to eq("test_image.png")
    end

    it "changes nothing — no write, no audit entry — when the gallery is unchanged" do
      a = attach_product_image!(product)
      b = attach_product_image!(product)
      before = ProductImage.order(:id).map(&:attributes)
      expect { expect(apply([ "image:#{a.id}", "image:#{b.id}" ])).to be_ok }.not_to change(AuditLog, :count)
      expect(ProductImage.order(:id).map(&:attributes)).to eq(before)
    end

    it "audits a change on the product" do
      a = attach_product_image!(product)
      b = attach_product_image!(product)
      apply([ "image:#{b.id}" ])
      entry = AuditLog.where(auditable: product, action: "gallery_update").sole
      expect(entry.metadata).to include("image_ids" => [ b.id ], "primary_image_id" => b.id, "removed_image_ids" => [ a.id ])
    end

    it "refuses another product's image, another business's upload, a reused upload and junk — changing nothing" do
      mine = attach_product_image!(product)
      other_product = business.products.create!(name: "Other", sku: "OT-1", initial_cost_price: 1, average_cost_price: 1)
      theirs = attach_product_image!(other_product)
      foreign_signed = staged_image_blob(business: other).signed_id(purpose: described_class::STAGE_PURPOSE)
      used = stage!
      expect(apply([ "image:#{mine.id}", "upload:#{used}" ])).to be_ok

      [ [ "image:#{theirs.id}" ], [ "upload:#{foreign_signed}" ], [ "upload:#{used}" ], [ "upload:forged" ], [ "nonsense" ] ].each do |entries|
        expect(apply(entries)).not_to be_ok
      end
      expect(product.images.reload.size).to eq(2)
      expect(theirs.reload.product).to eq(other_product)
    end

    it "refuses more than the maximum and duplicates" do
      signed = Array.new(ProductImage::MAX_PER_PRODUCT + 1) { stage! }
      expect(apply(signed.map { |s| "upload:#{s}" }).error).to eq(:too_many)
      image = attach_product_image!(product)
      expect(apply([ "image:#{image.id}", "image:#{image.id}" ]).error).to eq(:duplicate)
    end

    it "refuses a user who may not edit products, and another business's product" do
      signed = stage!
      expect(apply([ "upload:#{signed}" ], actor: viewer).error).to eq(:not_authorized)
      outsider = create(:user, :owner, business: other)
      expect(apply([ "upload:#{signed}" ], actor: outsider).error).to eq(:not_authorized)
      expect(ProductImage.count).to eq(0)
    end

    it "an empty list removes every image" do
      attach_product_image!(product)
      expect(apply([])).to be_ok
      expect(product.images.reload).to be_empty
    end
  end
end
