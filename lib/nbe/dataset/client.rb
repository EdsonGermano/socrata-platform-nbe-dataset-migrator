require 'addressable/uri'
require 'httparty'
require 'json'
require 'core/auth/client'

module NBE
  module Dataset
    # Class that wraps all calls to the Socrata APIs used for dataset migration
    class Client
      include HTTParty
      default_timeout(60 * 20) # set timeout to 20 min
      # debug_output($stdout) # uncomment for debug HTTParty output

      attr_accessor :domain, :app_token, :user, :password
      attr_reader :base_options, :log

      def initialize(domain, app_token, user, password, log = nil)
        domain = "https://#{domain}" unless domain.start_with?('http')
        @domain = domain
        @app_token = app_token
        @user = user
        @password = password
        @base_options = {
          headers: {
            'X-App-Token' => @app_token,
            'Content-Type' => 'application/json'
          },
          basic_auth: {
            username: @user,
            password: @password
          }
        }
        @base_options[:verify] = false if domain.include?('localhost')
        @log = log || Logger.new(STDOUT)
      end

      def get_migration(id)
        path = "api/migrations/#{id}"
        perform_get(path)
      end

      def get_data(id, query = {})
        path = "resource/#{id}.json"
        perform_get(path, query: query)
      end

      def ingress_data(id, data)
        path = "resource/#{id}"
        perform_post(path, body: data.to_json)
      end

      def get_dataset_metadata(id)
        path = "api/views/#{id}.json"
        perform_get(path)
      end

      def get_v1_metadata(id)
        path = "metadata/v1/dataset/#{id}.json"
        perform_get(path, headers: { 'Cookie' => auth.cookie })
      end

      def update_v1_metadata(id, metadata)
        path = "metadata/v1/dataset/#{id}.json"
        perform_put(
          path,
          headers: {
            'Cookie' => auth.cookie,
            'Content-Type' => 'application/json'
          },
          body: metadata.to_json
        )
      end

      def create_dataset(id)
        path = 'api/views'
        perform_post(path, body: id.to_json)
      end

      def publish_dataset(id)
        path = "api/views/#{id}/publication.json"
        perform_post(path)
      end

      def add_column(id, column)
        path = "api/views/#{id}/columns"
        perform_post(path, body: column.to_json)
      end

      private

      def auth
        @auth ||= Core::Auth::Client.new(
          domain,
          email: user,
          password: password
        )
      end

      def perform_get(path, options = {})
        uri = URI.join(domain, path)
        response = self.class.get(uri, base_options.merge(options))
        handle_error(path, response) unless response.code == 200
        JSON.parse(response.body)
      end

      def perform_post(path, options = {})
        uri = URI.join(domain, path)
        options = base_options.merge(options.merge(query: { nbe: true }))
        response = nil
        begin
          response = self.class.post(uri, options)
        rescue Net::ReadTimeout => ex
          log.warn ex.message
          log.warn ex.backtrace.join("\n")
        end
        if response.nil? || response.code != 200 # retry
          log.warn "Request failed to #{uri} with response #{response}, retrying in 30 secs"
          sleep 30
          response = self.class.post(uri, options)
        end
        handle_error(path, response, options) unless response.code == 200
        JSON.parse(response.body)
      end

      def perform_put(path, options = {})
        uri = URI.join(domain, path)
        options = base_options.merge(options)
        response = self.class.put(uri, options)
        # expect a 204 for the metadata PUT, might not always be 204
        handle_error(path, response, options) unless response.code == 204
      end

      def handle_error(path, response, options = nil)
        log.error "Error accessing #{URI.join(domain, path)}"
        log.error response
        if options
          options.delete(:body)
          options.delete(:basic_auth)
          log.error options
        end
        fail("Response code: #{response.code}")
      end
    end
  end
end
