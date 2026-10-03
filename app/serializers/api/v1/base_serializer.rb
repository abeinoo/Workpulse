module Api
  module V1
    # Minimal explicit serializer for API responses (see docs/api/conventions.md
    # → "Serialization"). Replaces controller-private `*_json` helpers for
    # endpoints migrated to the standard contract.
    #
    #   class AdvanceSerializer < Api::V1::BaseSerializer
    #     attributes :id, :user_id, :status
    #     attribute(:repaid_amount) { record.repaid_amount }
    #   end
    #
    #   AdvanceSerializer.one(advance, viewer: current_user)
    #   AdvanceSerializer.many(advances, viewer: current_user)
    #
    # Rules:
    # * Attributes are an explicit allowlist — there is no "all columns" mode.
    # * Credential / secret columns are rejected at class-definition time.
    # * Serializers never query: callers preload associations (`includes`).
    # * Permission-dependent fields read `viewer` (the current user) from context;
    #   they never re-implement policy logic.
    class BaseSerializer
      FORBIDDEN_ATTRIBUTES = %i[
        encrypted_password password password_confirmation
        reset_password_token reset_password_sent_at remember_created_at
        token device_token access_token refresh_token api_key secret
      ].freeze

      class_attribute :_fields, instance_accessor: false, default: [].freeze

      class << self
        def attributes(*names)
          names.each { |name| attribute(name) }
        end

        def attribute(name, &block)
          name = name.to_sym
          if FORBIDDEN_ATTRIBUTES.include?(name)
            raise ArgumentError, "#{self.name} may not serialize sensitive attribute #{name.inspect}"
          end

          self._fields = (_fields + [ [ name, block ] ]).freeze
        end

        def one(record, **context)
          return nil if record.nil?

          new(record, **context).to_h
        end

        def many(records, **context)
          records.map { |record| one(record, **context) }
        end
      end

      attr_reader :record, :context

      def initialize(record, **context)
        @record  = record
        @context = context
      end

      def viewer = context[:viewer]

      def to_h
        self.class._fields.each_with_object({}) do |(name, block), hash|
          hash[name] = block ? instance_exec(&block) : record.public_send(name)
        end
      end
    end
  end
end
