module Attachable
  extend ActiveSupport::Concern

  CONTENT_TYPE_LABELS = {
    "image/jpeg"       => "JPEG",
    "image/png"        => "PNG",
    "image/webp"       => "WebP",
    "image/gif"        => "GIF",
    "image/svg+xml"    => "SVG",
    "application/pdf"  => "PDF",
  }.freeze

  IMAGE_CONTENT_TYPES    = %w[image/jpeg image/png image/webp].freeze
  LOGO_CONTENT_TYPES     = %w[image/jpeg image/png image/webp image/svg+xml].freeze
  DOCUMENT_CONTENT_TYPES = %w[image/jpeg image/png image/webp application/pdf].freeze

  DEFAULT_MAX_SIZE      = 5.megabytes
  DEFAULT_LOGO_SIZE     = 5.megabytes
  DEFAULT_DOCUMENT_SIZE = 10.megabytes

  class_methods do
    # Call from a model to add size + content-type validators for a named attachment.
    #
    # Example:
    #   has_one_attached :avatar
    #   validates_attachment :avatar,
    #     content_types: Attachable::IMAGE_CONTENT_TYPES,
    #     max_size:      Attachable::DEFAULT_MAX_SIZE
    def validates_attachment(attachment_name,
                              content_types: IMAGE_CONTENT_TYPES,
                              max_size: DEFAULT_MAX_SIZE)
      validate :"validate_#{attachment_name}_attachment"

      # Define the private validator method on the class.
      define_method(:"validate_#{attachment_name}_attachment") do
        blob = public_send(attachment_name)
        return unless blob.attached?

        content_type = blob.blob.content_type

        unless content_types.include?(content_type)
          human_types = content_types
            .map { |t| CONTENT_TYPE_LABELS.fetch(t, t.split("/").last.upcase) }
            .join(", ")
          errors.add(attachment_name, :invalid_content_type,
                     message: I18n.t("attachments.errors.invalid_content_type",
                                     types: human_types,
                                     default: "must be one of: #{human_types}"))
        end

        if blob.blob.byte_size > max_size
          human_max = ActiveSupport::NumberHelper.number_to_human_size(max_size)
          errors.add(attachment_name, :file_too_large,
                     message: I18n.t("attachments.errors.file_too_large",
                                     max: human_max,
                                     default: "must be smaller than #{human_max}"))
        end
      end

      private :"validate_#{attachment_name}_attachment"
    end
  end
end
