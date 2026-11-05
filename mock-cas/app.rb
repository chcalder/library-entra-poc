# frozen_string_literal: true

# A deliberately small Apereo CAS stand-in for the "before" state.
# Implements the parts of CAS Protocol 3.0 a typical campus Rails app uses:
#
#   GET  /cas/login?service=...          login form (or SSO redirect if a TGC exists)
#   POST /cas/login                      check password, issue ST, redirect to service?ticket=ST-...
#   GET  /cas/p3/serviceValidate         validate ST, return XML with user + attributes
#   GET  /cas/serviceValidate            same (CAS 2.0 path, attributes included)
#   GET  /cas/logout?service=...         end the SSO session
#
# NOT for production: no TLS, no throttling, plain-text demo passwords.
# Uses only the Ruby standard library so it runs anywhere.

require "cgi"
require "erb"
require "securerandom"
require "uri"
require "yaml"

class MockCas
  TICKET_TTL = 300
  TGC = "CASTGC"

  def initialize(users:, clock: -> { Time.now })
    @users = users
    @clock = clock
    @tickets = {}  # ST-... => { user:, service:, issued_at: }
    @sessions = {} # TGC value => user
    @mutex = Mutex.new
  end

  def call(env)
    method = env["REQUEST_METHOD"]
    path = env["PATH_INFO"].to_s
    params = parse_query(env["QUERY_STRING"])

    case [method, path]
    in ["GET", "/cas/login"] then login_form(env, params)
    in ["POST", "/cas/login"] then login(env, params.merge(parse_query(read_body(env))))
    in ["GET", "/cas/p3/serviceValidate" | "/cas/serviceValidate"] then validate(params)
    in ["GET", "/cas/logout"] then logout(env, params)
    in ["GET", "/healthz"] then [200, { "content-type" => "text/plain" }, ["ok"]]
    else [404, { "content-type" => "text/plain" }, ["not found"]]
    end
  end

  private

  def login_form(env, params, error: nil)
    service = params["service"].to_s
    user = sso_user(env)
    return redirect_with_ticket(user, service) if user && !service.empty?

    html = ERB.new(LOGIN_TEMPLATE).result_with_hash(
      service: service, error: error, users: @users, h: ->(s) { CGI.escapeHTML(s.to_s) }
    )
    [error ? 401 : 200, { "content-type" => "text/html; charset=utf-8" }, [html]]
  end

  def login(env, params)
    username = params["username"].to_s.strip.downcase
    user = @users[username]
    unless user && user["password"] == params["password"]
      return login_form(env, params, error: "Invalid NetID or password")
    end

    tgc = "TGT-#{SecureRandom.hex(16)}"
    @mutex.synchronize { @sessions[tgc] = username }
    service = params["service"].to_s
    status, headers, body = if service.empty?
                              [200, { "content-type" => "text/plain" }, ["Signed in to Mock CAS as #{username}"]]
                            else
                              redirect_with_ticket(username, service)
                            end
    headers["set-cookie"] = "#{TGC}=#{tgc}; Path=/cas; HttpOnly; SameSite=Lax"
    [status, headers, body]
  end

  def redirect_with_ticket(username, service)
    ticket = "ST-#{SecureRandom.hex(20)}"
    @mutex.synchronize { @tickets[ticket] = { user: username, service: service, issued_at: @clock.call } }
    separator = service.include?("?") ? "&" : "?"
    [302, { "location" => "#{service}#{separator}ticket=#{CGI.escape(ticket)}" }, []]
  end

  def validate(params)
    ticket = params["ticket"].to_s
    service = params["service"].to_s
    record = @mutex.synchronize { @tickets.delete(ticket) } # service tickets are single use

    if ticket.empty? || service.empty?
      return xml(failure("INVALID_REQUEST", "ticket and service are required"))
    end
    return xml(failure("INVALID_TICKET", "Ticket #{ticket} not recognized")) unless record
    return xml(failure("INVALID_TICKET", "Ticket #{ticket} expired")) if @clock.call - record[:issued_at] > TICKET_TTL
    return xml(failure("INVALID_SERVICE", "Ticket was issued for another service")) unless record[:service] == service

    xml(success(record[:user]))
  end

  def logout(env, params)
    tgc = cookies(env)[TGC]
    @mutex.synchronize { @sessions.delete(tgc) } if tgc
    headers = { "set-cookie" => "#{TGC}=; Path=/cas; Max-Age=0" }
    service = params["service"].to_s
    if service.empty?
      [200, headers.merge("content-type" => "text/plain"), ["Signed out of Mock CAS"]]
    else
      [302, headers.merge("location" => service), []]
    end
  end

  def success(username)
    attrs = @users.fetch(username).fetch("attributes", {}).flat_map do |name, values|
      Array(values).map { |v| "      <cas:#{name}>#{CGI.escapeHTML(v.to_s)}</cas:#{name}>" }
    end
    <<~XML
      <cas:serviceResponse xmlns:cas="http://www.yale.edu/tp/cas">
        <cas:authenticationSuccess>
          <cas:user>#{CGI.escapeHTML(username)}</cas:user>
          <cas:attributes>
      #{attrs.join("\n")}
          </cas:attributes>
        </cas:authenticationSuccess>
      </cas:serviceResponse>
    XML
  end

  def failure(code, message)
    <<~XML
      <cas:serviceResponse xmlns:cas="http://www.yale.edu/tp/cas">
        <cas:authenticationFailure code="#{code}">#{CGI.escapeHTML(message)}</cas:authenticationFailure>
      </cas:serviceResponse>
    XML
  end

  def xml(body)
    [200, { "content-type" => "application/xml; charset=utf-8" }, [body]]
  end

  def sso_user(env)
    tgc = cookies(env)[TGC]
    tgc && @mutex.synchronize { @sessions[tgc] }
  end

  def cookies(env)
    env["HTTP_COOKIE"].to_s.split(/;\s*/).to_h { |pair| pair.split("=", 2).then { |k, v| [k, v.to_s] } }
  end

  def parse_query(string)
    URI.decode_www_form(string.to_s).to_h
  rescue ArgumentError
    {}
  end

  def read_body(env)
    input = env["rack.input"]
    return "" unless input

    input.rewind if input.respond_to?(:rewind)
    input.read.to_s
  end

  LOGIN_TEMPLATE = <<~HTML
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Mock CAS · Central Authentication Service</title>
    <style>
      body{font-family:system-ui,sans-serif;background:#f3f1ec;margin:0;color:#1d1d1b}
      main{max-width:380px;margin:8vh auto;background:#fff;border:1px solid #d8d4cc;border-radius:8px;padding:28px}
      h1{font-size:1.15rem;margin:0 0 4px}.sub{color:#6b6760;font-size:.85rem;margin:0 0 20px}
      label{display:block;font-size:.85rem;margin:12px 0 4px}input{width:100%;box-sizing:border-box;padding:9px;border:1px solid #bdb8ae;border-radius:5px;font-size:1rem}
      button{margin-top:18px;width:100%;padding:10px;border:0;border-radius:5px;background:#7a1f1f;color:#fff;font-size:1rem;cursor:pointer}
      .err{background:#fbe9e9;color:#7a1f1f;padding:8px 10px;border-radius:5px;font-size:.9rem}
      .users{margin-top:20px;font-size:.8rem;color:#6b6760}.users code{background:#f3f1ec;padding:1px 4px;border-radius:3px}
    </style></head>
    <body><main>
      <h1>Central Authentication Service</h1>
      <p class="sub">Mock CAS for the Library Entra POC</p>
      <% if error %><p class="err"><%= h.(error) %></p><% end %>
      <form method="post" action="/cas/login">
        <input type="hidden" name="service" value="<%= h.(service) %>">
        <label for="u">NetID</label><input id="u" name="username" autocomplete="username" required>
        <label for="p">Password</label><input id="p" name="password" type="password" autocomplete="current-password" required>
        <button type="submit">Sign in</button>
      </form>
      <div class="users">Demo NetIDs (password <code>password</code>):
        <% users.each_key do |u| %><code><%= h.(u) %></code> <% end %>
      </div>
    </main></body></html>
  HTML
end
