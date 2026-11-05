# frozen_string_literal: true

require "cgi"
require "net/http"
require "rexml/document"
require "uri"

# The "before" sign-in: a hand-rolled CAS 3.0 client of the kind many campus
# Rails apps carry (often via rack-cas or a before_action filter).
#
# Migration note: an alternative first step is to move CAS onto OmniAuth
# (omniauth-cas) so that the later switch to Entra is a strategy swap.
# This POC keeps CAS explicit so the before/after code is easy to compare.
class CasClient
  NS = { "cas" => "http://www.yale.edu/tp/cas" }.freeze
  Result = Struct.new(:user, :attributes, keyword_init: true)
  class ValidationError < StandardError; end

  # login_url / logout_url are what the BROWSER uses; validate_url is what the
  # SERVER uses (they differ inside Docker or a private network).
  def initialize(login_url:, validate_url:, logout_url:, http: nil)
    @login_url = login_url
    @validate_url = validate_url
    @logout_url = logout_url
    @http = http || method(:fetch)
  end

  def login_url(service:)
    with_query(@login_url, service: service)
  end

  def logout_url(service:)
    with_query(@logout_url, service: service)
  end

  def validate(ticket:, service:)
    raise ValidationError, "No CAS ticket was returned" if ticket.to_s.empty?

    parse(@http.call(URI(with_query(@validate_url, ticket: ticket, service: service))))
  end

  def parse(xml)
    doc = REXML::Document.new(xml)
    success = REXML::XPath.first(doc, "//cas:authenticationSuccess", NS)
    unless success
      failure = REXML::XPath.first(doc, "//cas:authenticationFailure", NS)
      code = failure&.attributes&.[]("code") || "UNKNOWN"
      raise ValidationError, "#{code}: #{failure&.text.to_s.strip}"
    end

    user = REXML::XPath.first(success, "cas:user", NS)&.text.to_s.strip
    raise ValidationError, "CAS response had no user" if user.empty?

    attributes = Hash.new { |h, k| h[k] = [] }
    REXML::XPath.each(success, "cas:attributes/*", NS) { |el| attributes[el.name] << el.text.to_s.strip }
    Result.new(user: user, attributes: attributes.to_h)
  rescue REXML::ParseException => e
    raise ValidationError, "Unreadable CAS response: #{e.message.lines.first}"
  end

  private

  def with_query(url, params)
    uri = URI(url)
    uri.query = URI.encode_www_form(URI.decode_www_form(uri.query.to_s) + params.to_a)
    uri.to_s
  end

  def fetch(uri)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                   open_timeout: 5, read_timeout: 10) { |h| h.get(uri.request_uri) }
    raise ValidationError, "CAS validation returned HTTP #{response.code}" unless response.code == "200"

    response.body
  end
end
