module Api
  module V1
    class SalaryProfilesController < BaseController
      before_action :set_target_user
      before_action :set_profile, only: [ :show, :update ]

      def index
        authorize SalaryProfile
        profiles = @target_user.salary_profiles.order(effective_from: :desc)
        render_success(profiles.map { |p| profile_json(p) })
      end

      def show
        authorize @profile
        render_success(profile_json(@profile))
      end

      def create
        authorize SalaryProfile
        result = Salary::ProfileUpdater.call(user: @target_user, params: profile_params)

        if result.success?
          render_success(profile_json(result.profile), status: :created)
        else
          render_error("Failed to create salary profile", errors: result.errors)
        end
      end

      # Only non-date-sensitive fields can be corrected in-place.
      # To change salary amount or type, create a new profile via POST.
      def update
        authorize @profile
        if @profile.update(profile_params.except(:effective_from, :salary_type))
          render_success(profile_json(@profile))
        else
          render_error("Failed to update salary profile", errors: @profile.errors.full_messages)
        end
      end

      private

      def set_target_user
        @target_user = policy_scope(User).find(params[:user_id])
      end

      def set_profile
        @profile = @target_user.salary_profiles.find(params[:id])
      end

      def profile_params
        params.require(:salary_profile)
              .permit(:salary_type, :base_amount, :currency, :effective_from)
      end

      def profile_json(profile)
        profile.slice(:id, :salary_type, :base_amount, :currency, :effective_from, :active)
      end
    end
  end
end
