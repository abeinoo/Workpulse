require "rails_helper"

RSpec.describe Business, type: :model do
  subject(:business) { create(:business) }

  # ── Logo ──────────────────────────────────────────────────────────────────
  describe "logo attachment" do
    it "declares has_one_attached :logo" do
      expect(business).to respond_to(:logo)
    end

    it "is valid without a logo" do
      expect(business).to be_valid
    end

    context "when attaching a valid PNG" do
      before do
        business.logo.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
          filename:     "logo.png",
          content_type: "image/png"
        )
      end

      it "is valid" do
        expect(business).to be_valid
      end

      it "reports logo as attached" do
        expect(business.logo).to be_attached
      end
    end

    context "when attaching a valid JPEG" do
      before do
        business.logo.attach(
          io:           StringIO.new("FAKE_JPEG_DATA"),
          filename:     "logo.jpg",
          content_type: "image/jpeg"
        )
      end

      it "is valid" do
        expect(business).to be_valid
      end
    end

    context "when attaching a valid WebP" do
      before do
        business.logo.attach(
          io:           StringIO.new("RIFF\x00\x00\x00\x00WEBPVP8 "),
          filename:     "logo.webp",
          content_type: "image/webp"
        )
      end

      it "is valid" do
        expect(business).to be_valid
      end
    end

    context "when attaching an SVG" do
      before do
        business.logo.attach(
          io:           StringIO.new("<svg xmlns='http://www.w3.org/2000/svg'></svg>"),
          filename:     "logo.svg",
          content_type: "image/svg+xml"
        )
      end

      it "is valid (SVG is allowed for logos)" do
        expect(business).to be_valid
      end
    end

    context "when attaching a disallowed content type" do
      before do
        business.logo.attach(
          io:           StringIO.new("GIF89a"),
          filename:     "logo.gif",
          content_type: "image/gif"
        )
      end

      it "is invalid" do
        expect(business).not_to be_valid
      end

      it "adds an error on :logo" do
        business.valid?
        expect(business.errors[:logo]).not_to be_empty
      end
    end

    context "when attaching a PDF (not allowed for logo)" do
      before do
        business.logo.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
          filename:     "logo.pdf",
          content_type: "application/pdf"
        )
      end

      it "is invalid" do
        expect(business).not_to be_valid
      end
    end

    context "when the file exceeds the size limit (5 MB)" do
      let(:big_io) { StringIO.new("x" * (Attachable::DEFAULT_LOGO_SIZE + 1)) }

      before do
        business.logo.attach(
          io:           big_io,
          filename:     "huge.png",
          content_type: "image/png"
        )
      end

      it "is invalid" do
        expect(business).not_to be_valid
      end

      it "reports a file-size error" do
        business.valid?
        expect(business.errors[:logo].join).to match(/smaller than/i)
      end
    end
  end

  # ── Stamp image ───────────────────────────────────────────────────────────
  describe "stamp_image attachment" do
    it "declares has_one_attached :stamp_image" do
      expect(business).to respond_to(:stamp_image)
    end

    it "is valid without a stamp_image" do
      expect(business).to be_valid
    end

    context "when attaching a valid PNG" do
      before do
        business.stamp_image.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
          filename:     "stamp.png",
          content_type: "image/png"
        )
      end

      it "is valid" do
        expect(business).to be_valid
      end

      it "reports stamp_image as attached" do
        expect(business.stamp_image).to be_attached
      end
    end

    context "when attaching a valid JPEG" do
      before do
        business.stamp_image.attach(
          io:           StringIO.new("FAKE_JPEG_DATA"),
          filename:     "stamp.jpg",
          content_type: "image/jpeg"
        )
      end

      it "is valid" do
        expect(business).to be_valid
      end
    end

    context "when attaching a valid WebP" do
      before do
        business.stamp_image.attach(
          io:           StringIO.new("WEBP_DATA"),
          filename:     "stamp.webp",
          content_type: "image/webp"
        )
      end

      it "is valid" do
        expect(business).to be_valid
      end
    end

    context "when attaching an SVG (not allowed for stamp)" do
      before do
        business.stamp_image.attach(
          io:           StringIO.new("<svg xmlns='http://www.w3.org/2000/svg'></svg>"),
          filename:     "stamp.svg",
          content_type: "image/svg+xml"
        )
      end

      it "is invalid" do
        expect(business).not_to be_valid
      end

      it "adds an error on :stamp_image" do
        business.valid?
        expect(business.errors[:stamp_image]).not_to be_empty
      end
    end

    context "when attaching a GIF (not allowed)" do
      before do
        business.stamp_image.attach(
          io:           StringIO.new("GIF89a"),
          filename:     "stamp.gif",
          content_type: "image/gif"
        )
      end

      it "is invalid" do
        expect(business).not_to be_valid
      end
    end

    context "when attaching a PDF (not allowed for stamp)" do
      before do
        business.stamp_image.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
          filename:     "stamp.pdf",
          content_type: "application/pdf"
        )
      end

      it "is invalid" do
        expect(business).not_to be_valid
      end
    end

    context "when the stamp_image exceeds 5 MB" do
      let(:big_io) { StringIO.new("x" * (Attachable::DEFAULT_MAX_SIZE + 1)) }

      before do
        business.stamp_image.attach(
          io:           big_io,
          filename:     "huge.png",
          content_type: "image/png"
        )
      end

      it "is invalid" do
        expect(business).not_to be_valid
      end

      it "reports a file-size error" do
        business.valid?
        expect(business.errors[:stamp_image].join).to match(/smaller than/i)
      end
    end
  end

  # ── Both attachments simultaneously ───────────────────────────────────────
  describe "simultaneous attachments" do
    it "accepts a valid logo and stamp_image together" do
      business.logo.attach(
        io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
        filename:     "logo.png",
        content_type: "image/png"
      )
      business.stamp_image.attach(
        io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
        filename:     "stamp.png",
        content_type: "image/png"
      )

      expect(business).to be_valid
    end
  end
end
