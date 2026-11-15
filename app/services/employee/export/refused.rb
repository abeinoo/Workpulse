module Employee
  module Export
    # An export request refused as a whole: its message is the reason code
    # (not_authorized, invalid_format, invalid_status, no_fields,
    # duplicate_fields, unauthorized_fields), translated under
    # admin.users.export.errors.
    class Refused < ArgumentError; end
  end
end
