# Create site.rb in production in order to do overrides of things like logging
load(File.expand_path('../site.rb', __FILE__)) if File.exist?(File.expand_path('../site.rb', __FILE__))

environment = ENV['RACK_ENV'] ||= 'development'

require 'rubygems'
require 'bundler'
Bundler.require(:default, environment.to_sym)

require 'singleton'
require 'active_support/core_ext/hash'
require 'fileutils'
require 'syslog_logger'
require 's3'
require 'yaml'
require 'optparse'
require 'json'
require 'set'
require 'timeout'
require 'time'
require 'pebblebed/sinatra'
require 'pebbles/river'
require 'excon'
require 'tempfile'
require 'uri'
require 'benchmark'

$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))
require 'tootsie'

unless defined?(LOGGER)
  $stdout.sync = true
  LOGGER = Logger.new($stdout)
  LOGGER.level = $DEBUG ? Logger::DEBUG : Logger::INFO
end

config_path = File.expand_path("../tootsie.conf", __FILE__)
if File.exist?(config_path)
  Tootsie::Configuration.instance.load_from_file(config_path)
end

Excon.defaults[:middlewares] << Excon::Middleware::RedirectFollower

Excon.defaults.merge!(omit_default_port: true)  # Otherwise can cause redirect issues
