module Api
  module V1
    class SessionsController < BaseController
      skip_before_action :authenticate_user!, only: [:create]

      def create
        user = find_user(session_params[:login].to_s.strip)

        if user&.active? && user.valid_password?(session_params[:password])
          sign_in(user)
          render_success(user_payload(user))
        else
          render_error("Invalid credentials", status: :unauthorized)
        end
      end

      def destroy
        sign_out(current_user)
        render_success({ message: "Logged out successfully" })
      end

      private

      def find_user(login)
        if login.include?("@")
          User.find_by("LOWER(email) = ?", login.downcase)
        else
          User.find_by(phone_number: login)
        end
      end

      def session_params
        params.require(:session).permit(:login, :password)
      end

      def user_payload(user)
        {
          id:             user.id,
          first_name:     user.first_name,
          last_name:      user.last_name,
          email:          user.email,
          phone_number:   user.phone_number,
          role:           user.owner? ? "owner" : "staff",
          # Extra admin/management capabilities granted via PermissionRole.
          # An empty array does NOT mean no access — all authenticated users
          # have the self_service capabilities listed below by default.
          permissions:    user.permission_role&.permissions || [],
          manages_area:   user.manages_area?,
          manages_branch: user.manages_branch?,
          business_id:    user.business_id,
          # Self-service capabilities available to every authenticated employee.
          # These are always true regardless of PermissionRole assignment.
          self_service: {
            can_create_requests:     true,
            can_view_own_attendance: true,
            can_view_own_payroll:    true,
            can_check_in:            user.allow_mobile_attendance?
          },
          checkin_branch_ids: ShiftAssignment.current
                                             .where(user: user)
                                             .pluck(:branch_id)
                                             .compact
                                             .uniq
        }
      end
    end
  end
end
