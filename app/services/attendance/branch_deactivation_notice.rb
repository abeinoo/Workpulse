module Attendance
  # Implements OrganizationAccess::BranchDeactivationNotices (registered in
  # config/initializers/branch_deactivation_notices.rb): the biometric devices
  # still registered to a branch about to be deactivated. Once the branch is
  # inactive, their punches are logged as rejected_branch_inactive and never
  # applied to attendance (Attendance::PunchService), so they need moving to an
  # active branch.
  #
  # Read-only: it never moves a device, clears its branch or blocks the
  # deactivation. Every device of the branch is listed by name, inactive ones
  # marked, with the count. One notice, or none when no device is registered
  # there.
  module BranchDeactivationNotice
    module_function

    def notices_for(branch:)
      devices = BiometricDevice.where(business_id: branch.business_id, branch_id: branch.id).order(:name).to_a
      return [] if devices.empty?

      [ OrganizationAccess::BranchDeactivationNotices::Notice.new(
        title:   I18n.t("attendance.deactivation_notice.title"),
        summary: I18n.t("attendance.deactivation_notice.summary",
                        devices: devices.map { |device| label(device) }.join(I18n.t("attendance.deactivation_notice.separator"))),
        lines:   [ OrganizationAccess::BranchDeactivationNotices::Line.new(
          label: I18n.t("attendance.deactivation_notice.devices_assigned"), value: devices.size
        ) ]
      ) ]
    end

    def label(device)
      return device.name if device.active?

      I18n.t("attendance.deactivation_notice.inactive_device", name: device.name)
    end
  end
end
