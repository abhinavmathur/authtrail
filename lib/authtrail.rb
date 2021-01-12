# dependencies
require "active_support"
require "geocoder"
require "warden"

# modules
require "auth_trail/controller"
require "auth_trail/engine"
require "auth_trail/manager"
require "auth_trail/version"

# integrations
require "devise/models/trailable"

module AuthTrail
  class << self
    attr_accessor :exclude_method, :geocode, :track_method, :identity_method
  end
  self.geocode = true
  self.identity_method = lambda do |request, opts, user|
    if user
      user.try(:email)
    else
      scope = opts[:scope]
      request.params[scope] && request.params[scope][:email] rescue nil
    end
  end

  def self.track(strategy: nil, scope: nil, identity: nil, success: nil, request: nil, user: nil, failure_reason: nil, activity_type:)
    request ||= Thread.current[:authtrail_request]

    info = {
      activity_type: activity_type,
      strategy: strategy,
      scope: scope,
      identity: identity,
      success: success,
      failure_reason: failure_reason,
      user: user
    }

    if request
      if request.params[:controller]
        info[:context] = "#{request.params[:controller]}##{request.params[:action]}"
      end
      info[:ip] = request.remote_ip
      info[:user_agent] = request.user_agent
      info[:referrer] = request.referrer
    end

    # if exclude_method throws an exception, default to not excluding
    exclude = AuthTrail.exclude_method && AuthTrail.safely(default: false) { AuthTrail.exclude_method.call(info) }

    unless exclude
      if AuthTrail.track_method
        AuthTrail.track_method.call(info)
      else
        activity = AuthTrail::Activity.create!(info)
        AuthTrail::GeocodeJob.perform_later(activity) if AuthTrail.geocode
      end
    end
  end

  def self.safely(default: nil)
    begin
      yield
    rescue => e
      warn "[authtrail] #{e.class.name}: #{e.message}"
      default
    end
  end
end

Warden::Manager.after_set_user except: :fetch do |user, auth, opts|
  AuthTrail::Manager.after_set_user(user, auth, opts)
end

Warden::Manager.before_failure do |env, opts|
  AuthTrail::Manager.before_failure(env, opts) if opts[:message]
end

Warden::Manager.before_logout do |user, auth, opts|
  AuthTrail::Manager.before_logout(user, auth, opts) if user
end

ActiveSupport.on_load(:action_controller) do
  include AuthTrail::Controller
end
