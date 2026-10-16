# Mobile keypads for numeric fields, app-wide.
#
# type="number" alone doesn't reliably pick the right keyboard on phones, so
# every number field rendered by Rails' own helpers (f.number_field and
# number_field_tag) gets an inputmode derived from the field's EXISTING rules —
# nothing about validation or precision changes:
#   • step with a fraction, or "any" → inputmode="decimal" (digits + separator)
#   • otherwise (whole-number step, or none = the browser's step 1) → "numeric"
# Only when the field can't be negative (min ≥ 0): iOS numeric/decimal keypads
# have no minus key, so signed fields keep the default number keyboard.
# An explicit inputmode always wins. Styling lives in application.css
# (input[type="number"]).
module NumberFieldInputmode
  def self.apply(options)
    return options if options.key?("inputmode") || options.key?(:inputmode)

    min = options["min"] || options[:min]
    return options if min.nil? || min.to_s.strip.empty? || min.to_d.negative?

    step = (options["step"] || options[:step]).to_s
    decimal = step == "any" || (step.present? && step.to_d.frac.nonzero?)
    options.merge("inputmode" => decimal ? "decimal" : "numeric")
  rescue ArgumentError, TypeError
    options
  end

  module Tag
    def render
      @options = NumberFieldInputmode.apply(@options)
      super
    end
  end

  module FormTag
    def number_field_tag(name, value = nil, options = {})
      super(name, value, NumberFieldInputmode.apply(options))
    end
  end
end

ActiveSupport.on_load(:action_view) do
  ActionView::Helpers::Tags::NumberField.prepend(NumberFieldInputmode::Tag)
  ActionView::Helpers::FormTagHelper.prepend(NumberFieldInputmode::FormTag)
end
