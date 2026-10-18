# Response bodies are HTML, so names and translated text in them are escaped:
# a name like "Leroy O'Keefe" renders as "Leroy O&#39;Keefe". Comparing a body
# against the raw string fails (or, for not_to include, passes vacuously)
# whenever Faker happens to generate such a name. Compare against the escaped
# form the page actually contains.
module HtmlTextHelpers
  def html_escaped(text) = ERB::Util.html_escape(text)
end

RSpec.configure do |config|
  config.include HtmlTextHelpers, type: :request
end
