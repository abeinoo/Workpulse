require "rails_helper"

RSpec.describe User, type: :model do
  subject(:user) { create(:user) }

  # ── Avatar (legacy) ───────────────────────────────────────────────────────
  describe "avatar attachment" do
    it "declares has_one_attached :avatar" do
      expect(user).to respond_to(:avatar)
    end

    it "is valid without an avatar" do
      expect(user).to be_valid
    end

    context "when attaching a valid PNG" do
      before do
        user.avatar.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
          filename:     "avatar.png",
          content_type: "image/png"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end

      it "reports avatar as attached" do
        expect(user.avatar).to be_attached
      end
    end

    context "when attaching a JPEG avatar" do
      before do
        user.avatar.attach(
          io:           StringIO.new("JPEG_DATA"),
          filename:     "avatar.jpg",
          content_type: "image/jpeg"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end
    end

    context "when attaching a WebP avatar" do
      before do
        user.avatar.attach(
          io:           StringIO.new("WEBP_DATA"),
          filename:     "avatar.webp",
          content_type: "image/webp"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end
    end

    context "when attaching an unsupported type (GIF)" do
      before do
        user.avatar.attach(
          io:           StringIO.new("GIF89a"),
          filename:     "avatar.gif",
          content_type: "image/gif"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "adds an error on :avatar" do
        user.valid?
        expect(user.errors[:avatar]).not_to be_empty
      end
    end

    context "when attaching a PDF as avatar (not allowed)" do
      before do
        user.avatar.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
          filename:     "avatar.pdf",
          content_type: "application/pdf"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end
    end

    context "when the avatar exceeds the size limit" do
      let(:big_io) { StringIO.new("x" * (Attachable::DEFAULT_MAX_SIZE + 1)) }

      before do
        user.avatar.attach(
          io:           big_io,
          filename:     "large.png",
          content_type: "image/png"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "reports a file-size error" do
        user.valid?
        expect(user.errors[:avatar].join).to match(/smaller than/i)
      end
    end
  end

  # ── ID card (legacy) ──────────────────────────────────────────────────────
  describe "id_card attachment" do
    it "declares has_one_attached :id_card" do
      expect(user).to respond_to(:id_card)
    end

    it "is valid without an id_card" do
      expect(user).to be_valid
    end

    context "when attaching a PDF id card" do
      before do
        user.id_card.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
          filename:     "id.pdf",
          content_type: "application/pdf"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end

      it "reports id_card as attached" do
        expect(user.id_card).to be_attached
      end
    end

    context "when attaching an image id card" do
      before do
        user.id_card.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
          filename:     "id.png",
          content_type: "image/png"
        )
      end

      it "is valid (images are allowed for id cards)" do
        expect(user).to be_valid
      end
    end

    context "when attaching an unsupported type (GIF)" do
      before do
        user.id_card.attach(
          io:           StringIO.new("GIF89a"),
          filename:     "id.gif",
          content_type: "image/gif"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "adds an error on :id_card" do
        user.valid?
        expect(user.errors[:id_card]).not_to be_empty
      end
    end

    context "when the id card exceeds the size limit" do
      let(:big_io) { StringIO.new("x" * (Attachable::DEFAULT_DOCUMENT_SIZE + 1)) }

      before do
        user.id_card.attach(
          io:           big_io,
          filename:     "large.pdf",
          content_type: "application/pdf"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "reports a file-size error" do
        user.valid?
        expect(user.errors[:id_card].join).to match(/smaller than/i)
      end
    end
  end

  # ── Profile photo ─────────────────────────────────────────────────────────
  describe "profile_photo attachment" do
    it "declares has_one_attached :profile_photo" do
      expect(user).to respond_to(:profile_photo)
    end

    it "is valid without a profile_photo" do
      expect(user).to be_valid
    end

    context "when attaching a valid PNG" do
      before do
        user.profile_photo.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
          filename:     "photo.png",
          content_type: "image/png"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end

      it "reports profile_photo as attached" do
        expect(user.profile_photo).to be_attached
      end
    end

    context "when attaching a JPEG" do
      before do
        user.profile_photo.attach(
          io:           StringIO.new("JPEG_DATA"),
          filename:     "photo.jpg",
          content_type: "image/jpeg"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end
    end

    context "when attaching a WebP" do
      before do
        user.profile_photo.attach(
          io:           StringIO.new("WEBP_DATA"),
          filename:     "photo.webp",
          content_type: "image/webp"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end
    end

    context "when attaching a GIF (not allowed)" do
      before do
        user.profile_photo.attach(
          io:           StringIO.new("GIF89a"),
          filename:     "photo.gif",
          content_type: "image/gif"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "adds an error on :profile_photo" do
        user.valid?
        expect(user.errors[:profile_photo]).not_to be_empty
      end
    end

    context "when attaching a PDF (not allowed for profile_photo)" do
      before do
        user.profile_photo.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
          filename:     "photo.pdf",
          content_type: "application/pdf"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end
    end

    context "when the profile_photo exceeds 5 MB" do
      let(:big_io) { StringIO.new("x" * (Attachable::DEFAULT_MAX_SIZE + 1)) }

      before do
        user.profile_photo.attach(
          io:           big_io,
          filename:     "large.png",
          content_type: "image/png"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "reports a file-size error" do
        user.valid?
        expect(user.errors[:profile_photo].join).to match(/smaller than/i)
      end
    end
  end

  # ── National ID front ─────────────────────────────────────────────────────
  describe "national_id_front attachment" do
    it "declares has_one_attached :national_id_front" do
      expect(user).to respond_to(:national_id_front)
    end

    it "is valid without a national_id_front" do
      expect(user).to be_valid
    end

    context "when attaching a PDF" do
      before do
        user.national_id_front.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
          filename:     "id_front.pdf",
          content_type: "application/pdf"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end

      it "reports national_id_front as attached" do
        expect(user.national_id_front).to be_attached
      end
    end

    context "when attaching a PNG image" do
      before do
        user.national_id_front.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
          filename:     "id_front.png",
          content_type: "image/png"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end
    end

    context "when attaching a GIF (not allowed)" do
      before do
        user.national_id_front.attach(
          io:           StringIO.new("GIF89a"),
          filename:     "id_front.gif",
          content_type: "image/gif"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "adds an error on :national_id_front" do
        user.valid?
        expect(user.errors[:national_id_front]).not_to be_empty
      end
    end

    context "when the national_id_front exceeds 10 MB" do
      let(:big_io) { StringIO.new("x" * (Attachable::DEFAULT_DOCUMENT_SIZE + 1)) }

      before do
        user.national_id_front.attach(
          io:           big_io,
          filename:     "large.pdf",
          content_type: "application/pdf"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "reports a file-size error" do
        user.valid?
        expect(user.errors[:national_id_front].join).to match(/smaller than/i)
      end
    end
  end

  # ── National ID back ──────────────────────────────────────────────────────
  describe "national_id_back attachment" do
    it "declares has_one_attached :national_id_back" do
      expect(user).to respond_to(:national_id_back)
    end

    it "is valid without a national_id_back" do
      expect(user).to be_valid
    end

    context "when attaching a PDF" do
      before do
        user.national_id_back.attach(
          io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
          filename:     "id_back.pdf",
          content_type: "application/pdf"
        )
      end

      it "is valid" do
        expect(user).to be_valid
      end
    end

    context "when attaching a GIF (not allowed)" do
      before do
        user.national_id_back.attach(
          io:           StringIO.new("GIF89a"),
          filename:     "id_back.gif",
          content_type: "image/gif"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "adds an error on :national_id_back" do
        user.valid?
        expect(user.errors[:national_id_back]).not_to be_empty
      end
    end

    context "when the national_id_back exceeds 10 MB" do
      let(:big_io) { StringIO.new("x" * (Attachable::DEFAULT_DOCUMENT_SIZE + 1)) }

      before do
        user.national_id_back.attach(
          io:           big_io,
          filename:     "large.png",
          content_type: "image/png"
        )
      end

      it "is invalid" do
        expect(user).not_to be_valid
      end

      it "reports a file-size error" do
        user.valid?
        expect(user.errors[:national_id_back].join).to match(/smaller than/i)
      end
    end
  end

  # ── All attachments simultaneously ────────────────────────────────────────
  describe "simultaneous attachments" do
    it "accepts profile_photo, national_id_front, and national_id_back together" do
      user.profile_photo.attach(
        io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
        filename:     "photo.png",
        content_type: "image/png"
      )
      user.national_id_front.attach(
        io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
        filename:     "front.pdf",
        content_type: "application/pdf"
      )
      user.national_id_back.attach(
        io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
        filename:     "back.pdf",
        content_type: "application/pdf"
      )

      expect(user).to be_valid
    end

    it "accepts a valid avatar and a valid id card at the same time (legacy)" do
      user.avatar.attach(
        io:           File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
        filename:     "avatar.png",
        content_type: "image/png"
      )
      user.id_card.attach(
        io:           File.open(Rails.root.join("spec/fixtures/files/test_document.pdf")),
        filename:     "id.pdf",
        content_type: "application/pdf"
      )

      expect(user).to be_valid
    end
  end
end
