# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../app"

class MockCasTest < Minitest::Test
  SERVICE = "http://localhost:3000/cas/callback"

  def setup
    @now = Time.at(1_000_000)
    @cas = MockCas.new(users: YAML.load_file(File.expand_path("../users.yml", __dir__)), clock: -> { @now })
  end

  def request(method, path, query: "", body: "", cookie: nil)
    env = { "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => query,
            "rack.input" => StringIO.new(body) }
    env["HTTP_COOKIE"] = cookie if cookie
    @cas.call(env)
  end

  def sign_in(user = "jstudent", password = "password")
    request("POST", "/cas/login", body: URI.encode_www_form(username: user, password: password, service: SERVICE))
  end

  def ticket_from(location)
    URI.decode_www_form(URI(location).query).to_h["ticket"]
  end

  def test_login_issues_a_ticket_that_validates_once_with_attributes
    status, headers, = sign_in
    assert_equal 302, status
    ticket = ticket_from(headers["location"])
    assert_match(/\AST-/, ticket)

    _, _, body = request("GET", "/cas/p3/serviceValidate", query: URI.encode_www_form(ticket: ticket, service: SERVICE))
    xml = body.join
    assert_includes xml, "<cas:user>jstudent</cas:user>"
    assert_includes xml, "<cas:eduPersonAffiliation>student</cas:eduPersonAffiliation>"
    assert_includes xml, "<cas:mail>jstudent@example.edu</cas:mail>"

    _, _, body = request("GET", "/cas/p3/serviceValidate", query: URI.encode_www_form(ticket: ticket, service: SERVICE))
    assert_includes body.join, 'code="INVALID_TICKET"', "service tickets are single use"
  end

  def test_wrong_password_is_rejected
    status, = sign_in("jstudent", "nope")
    assert_equal 401, status
  end

  def test_ticket_bound_to_service
    _, headers, = sign_in
    ticket = ticket_from(headers["location"])
    _, _, body = request("GET", "/cas/p3/serviceValidate",
                         query: URI.encode_www_form(ticket: ticket, service: "http://evil.example/cb"))
    assert_includes body.join, 'code="INVALID_SERVICE"'
  end

  def test_expired_ticket
    _, headers, = sign_in
    ticket = ticket_from(headers["location"])
    @now += 301
    _, _, body = request("GET", "/cas/p3/serviceValidate", query: URI.encode_www_form(ticket: ticket, service: SERVICE))
    assert_includes body.join, "expired"
  end

  def test_sso_session_skips_the_form_until_logout
    _, headers, = sign_in
    cookie = headers["set-cookie"].split(";").first

    status, headers2, = request("GET", "/cas/login", query: URI.encode_www_form(service: SERVICE), cookie: cookie)
    assert_equal 302, status
    assert ticket_from(headers2["location"])

    request("GET", "/cas/logout", cookie: cookie)
    status, = request("GET", "/cas/login", query: URI.encode_www_form(service: SERVICE), cookie: cookie)
    assert_equal 200, status
  end
end
