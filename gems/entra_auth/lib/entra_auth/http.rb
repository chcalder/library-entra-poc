# frozen_string_literal: true

module EntraAuth
  # Minimal HTTP helper. Every client takes an `http:` object with the same
  # two methods, so tests can pass a fake instead of stubbing Net::HTTP.
  module Http
    module_function

    # Returns [status_code, parsed_json_hash].
    def post_form(uri, form, headers: {})
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(form.transform_keys(&:to_s).reject { |_, v| v.nil? })
      headers.each { |k, v| request[k] = v }
      perform(uri, request)
    end

    def get_json(uri, headers: {})
      request = Net::HTTP::Get.new(uri)
      headers.each { |k, v| request[k] = v }
      perform(uri, request)
    end

    def perform(uri, request)
      request["Accept"] = "application/json"
      response = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == "https",
                                 open_timeout: 5, read_timeout: 15) do |http|
        http.request(request)
      end
      body = response.body.to_s.empty? ? {} : JSON.parse(response.body)
      [response.code.to_i, body]
    rescue JSON::ParserError
      [response.code.to_i, { "error" => "invalid_response", "error_description" => response.body.to_s[0, 200] }]
    end
  end
end
