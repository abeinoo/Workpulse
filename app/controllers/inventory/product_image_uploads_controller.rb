# Stages one product photo while a product is being created or edited
# (Inventory::ProductGalleryUpdater.stage): validated, stored as an unattached
# blob, answered with a signed id. Nothing is attached to any product until the
# product form is saved. JSON only (the gallery uploads with progress).
class Inventory::ProductImageUploadsController < Inventory::BaseController
  def create
    authorize Product, :manage_images?

    result = Inventory::ProductGalleryUpdater.stage(actor: current_user, file: params[:file])
    if result.ok?
      render json: { signed_id: result.signed_id, filename: result.filename }, status: :created
    else
      render json: { error: t("inventory.products.gallery.errors.#{result.error}",
                              max: Attachable::DEFAULT_MAX_SIZE / 1.megabyte) },
             status: :unprocessable_entity
    end
  end
end
