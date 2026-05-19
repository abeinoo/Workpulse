module Api
  module V1
    # Base controller for biometric device endpoints.
    # Authenticates via device token — not Devise session.
    class BiometricBaseController < ActionController::API
      include ApiResponder

      before_action :authenticate_device!

      private

      def authenticate_device!
        token = extract_token
        @current_device = BiometricDevice.active.find_by(token: token)

        unless @current_device
          render_unauthorized("Invalid or missing device token")
          return
        end

        @current_device.touch(:last_seen_at)
      end

      def extract_token
        auth_header = request.headers["Authorization"]
        return auth_header.delete_prefix("Bearer ").strip if auth_header&.start_with?("Bearer ")
        request.headers["X-Device-Token"].presence
      end

      def current_device
        @current_device
      end

      def current_business
        @current_device.business
      end
    end
  end
end
