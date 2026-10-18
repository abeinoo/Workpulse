require "rails_helper"

RSpec.describe AttachmentHelper, type: :helper do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "P", sku: "P-1", initial_cost_price: 0) }

  # identify: false forces the given content_type to stick — Active Storage's
  # default content-type sniffing would otherwise override a spoofed type
  # (e.g. claiming a PDF fixture is application/msword) with the real one.
  def receipt_with_invoice(filename:, content_type:)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 1, unit_cost: 1)
    r.save!
    r.invoices.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/#{filename}")),
      filename: filename,
      content_type: content_type,
      identify: false
    )
    r.invoices.first
  end

  describe "#document_viewer_tag" do
    it "renders a working inline link for a PNG image, not just the filename" do
      invoice = receipt_with_invoice(filename: "test_image.png", content_type: "image/png")

      html = helper.document_viewer_tag(invoice)

      expect(html).to be_present
      expect(html).to include("attachment-viewer--image")
      expect(html).to include(rails_blob_path(invoice, disposition: "inline"))
      expect(html).to include('target="_blank"')
    end

    it "treats any image/* content type (e.g. JPG) the same as PNG" do
      invoice = receipt_with_invoice(filename: "test_image.png", content_type: "image/jpeg")

      html = helper.document_viewer_tag(invoice)

      expect(html).to include("attachment-viewer--image")
    end

    it "renders a working inline-open link for a PDF" do
      invoice = receipt_with_invoice(filename: "test_document.pdf", content_type: "application/pdf")

      html = helper.document_viewer_tag(invoice)

      expect(html).to be_present
      expect(html).to include("attachment-viewer--pdf")
      expect(html).to include(rails_blob_path(invoice, disposition: "inline"))
      expect(html).to include(I18n.t("forms.open"))
    end

    it "renders a download link (not inline) for any other file type" do
      # The helper renders any persisted attachment (it builds blob URLs). Goods
      # receipt invoices only accept images/PDF, so attaching a Word file through
      # them never saves; build a persisted attachment of that type directly.
      receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      receipt.items.build(product: product, quantity: 1, unit_cost: 1)
      receipt.save!
      blob = ActiveStorage::Blob.create_and_upload!(
        io: File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
        filename: "test_document.doc", content_type: "application/msword", identify: false
      )
      invoice = ActiveStorage::Attachment.create!(name: "invoices", record: receipt, blob: blob)
      expect(invoice).to be_persisted

      html = helper.document_viewer_tag(invoice)

      expect(html).to include("attachment-viewer--file")
      expect(html).to include(rails_blob_path(invoice, disposition: "attachment"))
      expect(html).to include(I18n.t("forms.download"))
    end

    it "returns nil for a nil attachment (no error)" do
      expect(helper.document_viewer_tag(nil)).to be_nil
    end

    it "works when called on a bare ActiveStorage::Attachment from a has_many_attached association, not just an Attached::One/Many proxy" do
      invoice = receipt_with_invoice(filename: "test_image.png", content_type: "image/png")

      expect(invoice).to be_a(ActiveStorage::Attachment)
      expect(invoice).not_to respond_to(:attached?)
      expect { helper.document_viewer_tag(invoice) }.not_to raise_error
      expect(helper.document_viewer_tag(invoice)).to be_present
    end
  end
end
