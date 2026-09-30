module Api
  # Store for Rails' built-in `rate_limit` on API controllers.
  #
  # `rate_limit` captures its store when the controller class loads; this
  # module resolves Rails.cache (Solid Cache in production) at call time
  # instead, so the counter backend follows the app's cache configuration.
  # With a null cache store (test default) `increment` returns nil and no
  # limit is ever applied.
  module RateLimitStore
    module_function

    def increment(name, amount = 1, **options)
      Rails.cache.increment(name, amount, **options)
    end
  end
end
