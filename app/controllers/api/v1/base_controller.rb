module Api
  module V1
    class BaseController < ApplicationController
      include ApiResponder

      skip_before_action :verify_authenticity_token
      before_action :authenticate_user!

      rescue_from Pundit::NotAuthorizedError,      with: :handle_unauthorized
      rescue_from ActiveRecord::RecordNotFound,    with: :handle_not_found

      private

      def handle_unauthorized
        render_error("Forbidden", status: :forbidden)
      end

      def handle_not_found
        render_not_found
      end

      def current_business
        current_user&.business
      end

      def require_manager!
        render_unauthorized unless current_user.super_admin? || current_user.branch_manager?
      end
    end
  end
end
