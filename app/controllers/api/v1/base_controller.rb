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
    # * Api::ErrorHandling     — legacy by default; `standard_api_contract!` opts in
    # * Api::Pagination        — paginate / paginate_if_requested
    # * Api::RequestContext    — request_id + actor ids for structured request logs
    #
    # No business logic belongs here.
    class BaseController < ApplicationController
      include ApiResponder
      include Api::StandardResponses
      include Api::ErrorHandling
      include Api::Pagination
      include Api::RequestContext

      skip_before_action :verify_authenticity_token
      before_action :authenticate_user!

      private

      def current_business
        current_user&.business
      end

      def require_manager!
        render_unauthorized unless current_user.can?(:manage_employees) || current_user.can?(:view_employees)
      end
    end
  end
end
