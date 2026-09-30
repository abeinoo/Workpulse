module Api
  module V1
    # Base for staff-facing /api/v1 endpoints (see docs/api/conventions.md).
    #
    # Authentication is the existing Devise session (the same one the Rails web
    # app uses — see docs/api/authentication.md); authorization is Pundit with
    # the existing policies. This class only wires shared API plumbing:
    #
    # * ApiResponder           — legacy envelope helpers (render_success/render_error)
    # * Api::StandardResponses — standard envelope helpers (render_api_success/…)
    #
    # No business logic belongs here.
    class BaseController < ApplicationController
      include ApiResponder
      include Api::StandardResponses

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
        render_unauthorized unless current_user.can?(:manage_employees) || current_user.can?(:view_employees)
      end
    end
  end
end
