#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'json'
require 'logger'
require 'rest-client'
require 'google/cloud/firestore'

# Class that consumes the Google Cloud Status Dashboard JSON feed and posts corresponding alerts to a specified
# Slack channel.
class CloudStatusAlerter
  DATE_TIME_FORMAT     = '%A %d %b %Y %H:%M:%S UTC'
  FIRESTORE_COLLECTION = 'gcp-status-alerter-updates-test'
  JSON_FEED_URL        = 'https://status.cloud.google.com/incidents.json'
  URI_ROOT             = 'https://status.cloud.google.com'
  SERVICES_OF_INTEREST = ['Cloud Developer Tools',
                          'Cloud Filestore',
                          'Cloud Firestore',
                          'Cloud Key Management Service',
                          'Cloud Memorystore',
                          'Cloud Security Command Center',
                          'Cloud Spanner',
                          'Google App Engine',
                          'Google BigQuery',
                          'Google Cloud Bigtable',
                          'Google Cloud Console',
                          'Google Cloud Datastore',
                          'Google Cloud DNS',
                          'Google Cloud Functions',
                          'Google Cloud Networking',
                          'Google Cloud Pub/Sub',
                          'Google Cloud Scheduler',
                          'Google Cloud SQL',
                          'Google Cloud Storage',
                          'Google Cloud Support',
                          'Google Compute Engine',
                          'Google Kubernetes Engine',
                          'Google Stackdriver',
                          'Identity and Access Management'].freeze

  Update = Struct.new(:number, :service, :timestamp, :text, :uri)

  def initialize
    @logger = Logger.new($stdout)
    initialize_firestore_client
  end

  def run
    json = JSON.parse(RestClient.get(JSON_FEED_URL))
    raise "Unable to retrieve JSON feed from #{JSON_FEED_URL}" unless json

    latest = json.first
    service_name = latest['service_name']
    return unless SERVICES_OF_INTEREST.include?(service_name)

    update = Update.new(latest['number'],
                        service_name,
                        DateTime.rfc3339(latest['most-recent-update']['when']).to_s,
                        latest['most-recent-update']['text'],
                        latest['uri'])

    formatted_timestamp = DateTime.parse(update.timestamp).strftime(DATE_TIME_FORMAT)
    text = "*#{update.service}*\n#{formatted_timestamp}\n\n#{update.text}\n\n#{URI_ROOT}#{update.uri}"    
    post_slack_message(text, 'gcp', 'GCP - Cloud Status Bot') unless in_firestore?(FIRESTORE_COLLECTION, update.number, update.timestamp, update.text)
    save_to_firestore(FIRESTORE_COLLECTION, update.number, update.timestamp, update.text)
  end

  private

  def in_firestore?(collection, key, timestamp, text)
    doc = @firestore_client.doc "#{collection}/#{key}"
    snapshot = doc.get
    return false if snapshot.data.nil?

    snapshot[:timestamp].eql?(timestamp) && snapshot[:text].eql?(text)
  end

  def initialize_firestore_client
    firestore_project     = ENV['FIRESTORE_PROJECT']
    firestore_credentials = ENV['FIRESTORE_CREDENTIALS']
    raise 'Missing FIRESTORE_PROJECT environment variable' unless firestore_project
    raise 'Missing FIRESTORE_CREDENTIALS environment variable' unless firestore_credentials

    Google::Cloud::Firestore.configure do |config|
      config.project_id  = firestore_project
      config.credentials = firestore_credentials
    end

    @firestore_client = Google::Cloud::Firestore.new
  end

  def post_slack_message(text, icon, username)
    payload = {
      'channel': ENV['STATUS_ALERTS_SLACK_CHANNEL'],
      'icon_emoji': ":#{icon}:",
      'username': username,
      'text': text,
      'attachments': []
    }.to_json.encode('UTF-8')
    headers = { 'Content-Type': 'application/json' }
    begin
      RestClient.post(ENV['SLACK_WEBHOOK'].chomp, payload, headers)
      @logger.info text
    rescue RestClient::ExceptionWithResponse => e
      @logger.error("Error posting to Slack: HTTP #{e.response.code} #{e.response}")
    end
  end

  def save_to_firestore(collection, key, timestamp, text)
    doc = @firestore_client.doc "#{FIRESTORE_COLLECTION}/#{key}"
    doc.set(timestamp: timestamp, text: text)
  end
end

CloudStatusAlerter.new.run