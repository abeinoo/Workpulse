module ApiResponder
  extend ActiveSupport::Concern

  def render_success(data, status: :ok)
    render json: { success: true, data: data }, status: status
  end

  def render_error(message, status: :unprocessable_entity, errors: [])
    render json: { success: false, message: message, errors: errors }, status: status
  end

  def render_not_found(message = "Record not found")
    render_error(message, status: :not_found)
  end

  def render_unauthorized(message = "Not authorized")
    render_error(message, status: :unauthorized)
  end
end
