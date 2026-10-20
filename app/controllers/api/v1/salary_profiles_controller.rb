module Api
  module V1
    class SalaryProfilesController < BaseController
      before_action :set_target_user

      # The SalaryProfilePolicy scope decides what is visible: only ever the
      # employee's current profile — their own, or, with view_payroll inside the
      # view_payroll scope, another employee's. Superseded profiles are never
      # returned, by list or by id.
      def index
        authorize SalaryProfile
        profiles = policy_scope(SalaryProfile).where(user: @target_user).order(effective_from: :desc).to_a
        Salary::ViewAudit.record(actor: current_user, employee: @target_user, profiles: profiles,
                                 source: "api_salary_profiles")
        render_success(profiles.map { |p| profile_json(p) })
      end

      def show
        @profile = policy_scope(SalaryProfile).where(user: @target_user).find(params[:id])
        authorize @profile
        Salary::ViewAudit.record(actor: current_user, employee: @target_user, profiles: [ @profile ],
                                 source: "api_salary_profile")
        render_success(profile_json(@profile))
      end

      # The response echoes only the profile just created from the request's own
      # values — no existing salary data, so no salary view is recorded.
      def create
        authorize SalaryProfile.new(user_id: @target_user.id) # standalone probe, not built into the association
        result = Salary::ProfileUpdater.call(user: @target_user, params: profile_params, actor: current_user, source: "api")

        if result.success?
          render_success(profile_json(result.profile), status: :created)
        else
          render_error("Failed to create salary profile", errors: result.errors)
        end
      end

      # Only non-date-sensitive fields can be corrected in-place.
      # To change salary amount or type, create a new profile via POST.
      # The response returns the whole current profile (unchanged fields too),
      # so it is recorded as a salary view.
      def update
        @profile = @target_user.salary_profiles.find(params[:id])
        authorize @profile
        result = Salary::ProfileCorrector.call(profile_id: @profile.id, actor: current_user, source: "api",
                                               attributes: profile_params.except(:effective_from, :salary_type))

        if result.success?
          Salary::ViewAudit.record(actor: current_user, employee: @target_user, profiles: [ result.profile ],
                                   source: "api_salary_profile_update")
          render_success(profile_json(result.profile))
        else
          render_error("Failed to update salary profile", errors: result.errors)
        end
      end

      private

      def set_target_user
        @target_user = policy_scope(User).find(params[:user_id])
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
