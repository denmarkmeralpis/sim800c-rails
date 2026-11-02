# frozen_string_literal: true

# Requests against the dummy app (engine mounted at /sms-gateway) with explicit cookies and keys,
# like sms-gateway's fetch-based API tests.
module ApiHelpers
  MOUNT = "/sms-gateway"

  Response = Struct.new(:status, :headers, :body)

  def req(path, method: nil, body: nil, session: nil, key: nil, csrf: true, headers: {}, raw: nil)
    env = { "REMOTE_ADDR" => "127.0.0.1", method: (method || (body || raw ? "POST" : "GET")).to_s.upcase }
    payload = raw || (body.nil? ? nil : JSON.generate(body))
    if payload
      env[:input] = payload
      env["CONTENT_TYPE"] = "application/json"
    end
    if session
      env["HTTP_COOKIE"] = session[:cookie]
      env["HTTP_X_CSRF_TOKEN"] = session[:csrf] if csrf
    end
    env["HTTP_X_API_KEY"] = key if key
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    res = Rack::MockRequest.new(Rails.application).request(env.delete(:method), MOUNT + path, env)
    parsed = res.body.empty? ? nil : (JSON.parse(res.body) rescue res.body) # rubocop:disable Style/RescueModifier
    Response.new(res.status, res.headers, parsed)
  end

  def login(username, password)
    res = req("/api/auth/login", body: { username: username, password: password })
    assert_equal 200, res.status, res.body.inspect
    { cookie: res.headers["set-cookie"].split(";").first, csrf: res.body["csrfToken"] }
  end

  def create_key(admin, scopes)
    res = req("/api/v1/admin/keys", body: { name: "key-#{scopes.join('+')}", scopes: scopes }, session: admin)
    assert_equal 201, res.status, res.body.inspect
    res.body["key"]
  end
end
