module AttachmentHelper
  # ── Variant presets ────────────────────────────────────────────────────────

  AVATAR_VARIANTS = {
    thumb:   { resize_to_fill: [ 40, 40 ],   format: :webp, saver: { quality: 80 } },
    default: { resize_to_fill: [ 80, 80 ],   format: :webp, saver: { quality: 85 } },
    large:   { resize_to_fill: [ 160, 160 ], format: :webp, saver: { quality: 85 } },
  }.freeze

  LOGO_VARIANTS = {
    thumb:   { resize_to_fill:  [ 48, 48 ],   format: :webp, saver: { quality: 80 } },
    default: { resize_to_limit: [ 300, 100 ], format: :webp, saver: { quality: 90 } },
  }.freeze

  STAMP_VARIANTS = {
    thumb:   { resize_to_fill:  [ 48, 48 ],   format: :webp, saver: { quality: 80 } },
    default: { resize_to_limit: [ 200, 100 ], format: :webp, saver: { quality: 85 } },
  }.freeze

  NATIONAL_ID_VARIANTS = {
    thumb:   { resize_to_limit: [ 160, 100 ], format: :webp, saver: { quality: 80 } },
    preview: { resize_to_limit: [ 640, 400 ], format: :webp, saver: { quality: 85 } },
  }.freeze

  # ── URL helpers ────────────────────────────────────────────────────────────

  def avatar_url(user, size: :default)
    return nil unless user&.avatar&.attached?

    variant = AVATAR_VARIANTS.fetch(size, AVATAR_VARIANTS[:default])
    url_for(user.avatar.variant(variant))
  rescue => e
    Rails.logger.warn("[AttachmentHelper] avatar_url failed for user #{user&.id}: #{e.message}")
    nil
  end

  def profile_photo_url(user, size: :default)
    return nil unless user&.profile_photo&.attached?

    variant = AVATAR_VARIANTS.fetch(size, AVATAR_VARIANTS[:default])
    url_for(user.profile_photo.variant(variant))
  rescue => e
    Rails.logger.warn("[AttachmentHelper] profile_photo_url failed for user #{user&.id}: #{e.message}")
    nil
  end

  def logo_url(business, size: :default)
    return nil unless business&.logo&.attached?

    variant = LOGO_VARIANTS.fetch(size, LOGO_VARIANTS[:default])
    url_for(business.logo.variant(variant))
  rescue => e
    Rails.logger.warn("[AttachmentHelper] logo_url failed for business #{business&.id}: #{e.message}")
    nil
  end

  def stamp_image_url(business, size: :default)
    return nil unless business&.stamp_image&.attached?

    variant = STAMP_VARIANTS.fetch(size, STAMP_VARIANTS[:default])
    url_for(business.stamp_image.variant(variant))
  rescue => e
    Rails.logger.warn("[AttachmentHelper] stamp_image_url failed for business #{business&.id}: #{e.message}")
    nil
  end

  # Returns a variant URL only for image content types; PDFs return nil.
  def national_id_url(user, attachment_name, size: :thumb)
    attachment = user&.public_send(attachment_name)
    return nil unless attachment&.attached?
    return nil unless attachment.blob.content_type.start_with?("image/")

    variant = NATIONAL_ID_VARIANTS.fetch(size, NATIONAL_ID_VARIANTS[:thumb])
    url_for(attachment.variant(variant))
  rescue => e
    Rails.logger.warn("[AttachmentHelper] national_id_url failed for user #{user&.id}: #{e.message}")
    nil
  end

  # Renders a read-only document viewer for a national ID attachment:
  # • image → clickable thumbnail (opens full size in new tab)
  # • PDF   → icon + filename + open link
  # Returns nil when the attachment is not present.
  def national_id_viewer_tag(user, attachment_name)
    attachment = user.public_send(attachment_name)
    return nil unless attachment.attached?

    blob = attachment.blob
    if blob.content_type.start_with?("image/")
      preview_url = national_id_url(user, attachment_name, size: :preview)
      full_url    = url_for(attachment)
      content_tag(:div, class: "attachment-viewer attachment-viewer--image") do
        link_to(full_url, target: "_blank", rel: "noopener noreferrer", class: "attachment-viewer__link") do
          image_tag(preview_url, alt: attachment_name.to_s.humanize,
                    class: "attachment-viewer__img", loading: "lazy")
        end
      end
    else
      content_tag(:div, class: "attachment-viewer attachment-viewer--pdf") do
        content_tag(:span, "PDF", class: "attachment-viewer__pdf-icon") +
          content_tag(:div, class: "attachment-viewer__pdf-meta") do
            content_tag(:span, blob.filename.to_s, class: "attachment-viewer__pdf-name") +
              link_to(t("forms.open"), url_for(attachment),
                      target: "_blank", rel: "noopener noreferrer",
                      class: "btn btn-sm btn-ghost")
          end
      end
    end
  rescue => e
    Rails.logger.warn("[AttachmentHelper] national_id_viewer_tag failed for user #{user&.id}: #{e.message}")
    nil
  end

  # Renders a read-only viewer for any Active Storage attachment (e.g. a goods
  # receipt invoice): image → clickable thumbnail, PDF → icon + filename + open
  # link (both open inline in a new tab), anything else → icon + filename +
  # download link. Mirrors national_id_viewer_tag but works on a bare
  # ActiveStorage::Attachment (e.g. from iterating a has_many_attached
  # association) rather than a named user attachment — ActiveStorage::Attachment
  # has no #attached? method (that only exists on the Attached::One/Many proxy
  # returned by the named accessor), so it must not be used as the presence guard.
  def document_viewer_tag(attachment)
    return nil unless attachment
    return nil unless (blob = attachment.blob)

    if blob.content_type.start_with?("image/")
      content_tag(:div, class: "attachment-viewer attachment-viewer--image") do
        link_to(rails_blob_path(attachment, disposition: "inline"),
                target: "_blank", rel: "noopener noreferrer", class: "attachment-viewer__link") do
          image_tag(url_for(attachment.variant(resize_to_limit: [ 640, 400 ], format: :webp, saver: { quality: 85 })),
                    alt: blob.filename.to_s, class: "attachment-viewer__img", loading: "lazy")
        end
      end
    elsif blob.content_type == "application/pdf"
      content_tag(:div, class: "attachment-viewer attachment-viewer--pdf") do
        content_tag(:span, "PDF", class: "attachment-viewer__pdf-icon") +
          content_tag(:div, class: "attachment-viewer__pdf-meta") do
            content_tag(:span, blob.filename.to_s, class: "attachment-viewer__pdf-name") +
              link_to(t("forms.open"), rails_blob_path(attachment, disposition: "inline"),
                      target: "_blank", rel: "noopener noreferrer",
                      class: "btn btn-sm btn-ghost")
          end
      end
    else
      extension = blob.filename.extension_without_delimiter.presence&.upcase || "FILE"
      content_tag(:div, class: "attachment-viewer attachment-viewer--file") do
        content_tag(:span, extension, class: "attachment-viewer__pdf-icon") +
          content_tag(:div, class: "attachment-viewer__pdf-meta") do
            content_tag(:span, blob.filename.to_s, class: "attachment-viewer__pdf-name") +
              link_to(t("forms.download"), rails_blob_path(attachment, disposition: "attachment"),
                      class: "btn btn-sm btn-ghost")
          end
      end
    end
  rescue => e
    Rails.logger.warn("[AttachmentHelper] document_viewer_tag failed: #{e.message}")
    raise if Rails.env.test?
    nil
  end

  # ── Image tag helpers ──────────────────────────────────────────────────────

  # Renders a unified circular avatar for a user.
  # Both photo and initials share the same .avatar wrapper div so dimensions,
  # border, border-radius, and alignment are always identical.
  def user_avatar_tag(user, size: :default, **html_opts)
    url = profile_photo_url(user, size: size) || avatar_url(user, size: size)
    size_class = avatar_size_class(size)

    if url
      extra_class = html_opts.delete(:class)
      klass = [ "avatar", size_class, extra_class ].compact.join(" ")
      content_tag(:div, html_opts.merge(class: klass)) do
        image_tag(url, alt: user.full_name, loading: "lazy", class: "avatar-img")
      end
    else
      initials_avatar_tag(user.full_name, size: size, **html_opts)
    end
  end

  # Renders an <img> for the business logo, or a text fallback <span>.
  def business_logo_tag(business, size: :default, **html_opts)
    url = logo_url(business, size: size)

    if url
      html_opts = { alt: business.name, loading: "lazy", class: "logo-img" }.merge(html_opts)
      image_tag(url, **html_opts)
    else
      content_tag(:span, business.name.first(2).upcase,
                  { class: "avatar avatar-placeholder" }.merge(html_opts))
    end
  end

  # Renders the sidebar user avatar using the same unified component as the rest of the app.
  def sidebar_user_avatar_tag(user)
    user_avatar_tag(user, size: :thumb)
  end

  private

  def initials_avatar_tag(full_name, size: :default, **html_opts)
    initials = full_name.to_s.split.map(&:first).first(2).join.upcase
    initials = "?" if initials.blank?
    size_class = avatar_size_class(size)
    extra_class = html_opts.delete(:class)
    klass = [ "avatar", size_class, "avatar-placeholder", extra_class ].compact.join(" ")
    content_tag(:div, initials, html_opts.merge(class: klass, aria: { label: full_name }))
  end

  def avatar_size_class(size)
    { thumb: "avatar--sm", large: "avatar--xl" }.fetch(size, "avatar--lg")
  end
end
