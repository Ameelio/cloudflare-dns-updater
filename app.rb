#!/usr/bin/env ruby

# PUT zones/:zone_identifier/dns_records/:identifier

require 'net/http'
require 'uri'
require 'openssl'
require 'json'

REQUEST_CLASS = {
  get:    Net::HTTP::Get,
  post:   Net::HTTP::Post,
  delete: Net::HTTP::Delete,
}.freeze

def debug? = ENV['DEBUG_OUTPUT'] =~ /[Yy]/

def debug(msg)
  if debug?
    puts "[DEBUG]: #{msg}"
  end
end

def info(msg)
  puts "[INFO]: #{msg}"
end

def warning(msg)
  puts "[WARNING]: #{msg}"
end

def error(msg)
  puts "[ERROR]: #{msg}"
end

def http_request(method, url, bearer:, body: nil, verify_ssl: true)
  uri = URI(url)
  req = REQUEST_CLASS.fetch(method).new(uri)
  req['Authorization'] = "Bearer #{bearer}"
  req['Accept']        = 'application/json'
  req['Content-Type']  = 'application/json'
  req.body = JSON.generate(body) if body

  Net::HTTP.start(
    uri.host, uri.port,
    use_ssl: uri.scheme == 'https',
    verify_mode: verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
  ) { |h| h.request(req).body }
end

def get_nodes
  # In k8s, the ca cert is mounted at /run/secrets/kubernetes.io/serviceaccount/ca.crt;
  # cert verification is disabled here for parity with prior behavior.
  resp = http_request(
    :get,
    "https://kubernetes.default.svc/api/v1/nodes",
    bearer: k8s_token,
    verify_ssl: false,
  )

  # This object is very large, so comment out for now
  # debug("Retrieved nodes:  #{resp}")

  JSON.parse(resp)
end

def get_node_ips
  # Get list of all nodes from the k8s API, then filter out only the ones that are part of the main or infra pools,
  # and extract the ExternalIP of each node
  get_nodes()['items']
    .select { |item| ['main', 'infra'].include?(item['metadata']['labels']['ameelio.org/pool']) }
    .map { |item|
        item['status']['addresses']
          .select { |a| a['type'] == 'ExternalIP' }
          .map { |a| a['address'] }
      }
    .flatten
end

def get_a_records
  resp = http_request(
    :get,
    "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records?name=#{full_hostname}&type=A",
    bearer: cf_token,
  )

  js = JSON.parse(resp)

  if js["success"] == false
    error("Cloudflare API call failed.  Cloudflare returned:")
    error(JSON.pretty_unparse(js))

    if js["errors"][0]["code"] == 10000
      error("Cloudflare Authentication failed.  Double check the CF_TOKEN value")
      exit 1
    end
  end

  js
end

def relevant_a_records
  get_a_records['result']
    .select { |a_record| a_record['name'] =~ /^#{hostname}/i }
    .map { |a_record| a_record['content'] }
end

def create_a_record(ip:)
  # POST zones/:zone_identifier/dns_records
  info "Creating A record for IP #{ip}"

  result = http_request(
    :post,
    "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records",
    bearer: cf_token,
    body: {
      type: "A",
      name: hostname,
      content: ip,
      ttl: 360,
      proxied: false
    },
  )

  info("Creation result:  #{result}")

  result
end

def remove_a_record(ip:)
  info "Removing A record for IP #{ip}"

  debug "Retrieving ID for A record for IP #{ip}"

  # First get the record's ID
  # TODO:  Limit search to cvh-staging.ameelio.org
  resp = http_request(
    :get,
    "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records?type=A&match=all&content=#{ip}&name=#{full_hostname}",
    bearer: cf_token,
  )

  debug "Parsing ID for A record for IP #{ip}"

  record = JSON.parse(resp)['result']
    .select { |a_record| a_record['content'] == ip }
    .first
  id = record['id']

  debug "Parsed ID for A record for IP #{ip}.  ID is '#{id}'"

  # DELETE zones/:zone_identifier/dns_records/:identifier
  result = http_request(
    :delete,
    "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records/#{id}",
    bearer: cf_token,
  )

  info("Removal result:  #{result}")
end

def read_k8s_token = File.read('/var/run/secrets/kubernetes.io/serviceaccount/token')

def k8s_token
  $k8s_token ||= read_k8s_token
  $k8s_token
end

def cf_token = ENV['CF_TOKEN']
def hostname = ENV['HOSTNAME']
def domain = ENV['DOMAIN']
def full_hostname = "#{hostname}.#{domain}"
def zone_id = ENV['ZONE_ID']

def cf_auth_email = ENV['CF_AUTH_EMAIL']
def cf_auth_key = ENV['CF_AUTH_KEY']

def main(args)
  info("Starting Cloudflare updater cycle")

  info("- Start time: #{`date`}")
  info("- Hostname: #{hostname}")
  info("- Domain: #{domain}")
  info("- Full Hostname: #{full_hostname}")
  info("- Zone ID: #{zone_id}")

  # Get the IP addresses for all the nodes in our cluster
  node_ips = get_node_ips
  info("Successfully Retrieved node_ips: #{node_ips}")

  # Get all A records from Cloudflare
  cf_a_records = relevant_a_records
  info("Successfully retrieved relevant A records from Cloudflare: #{cf_a_records}")

  a_record_creation_errors = []

  node_ips.each do |node_ip|
    # If there's not an A record for this IP already, add it
    unless cf_a_records.include?(node_ip)
      res = create_a_record(ip: node_ip)

      # Check that res hash contains "success":true
      unless res["success"] == true
        err_msg = "Failed to create A record for IP #{node_ip}.  Cloudflare returned:  #{res}"
        error(err_msg)
        a_record_creation_errors.push(err_msg)
      end
    end
  end

  if a_record_creation_errors.any?
    error("Errors occurred during Cloudflare update cycle.  Exiting with failure status.")
    exit 1
  end

  cf_a_records.each do |a_record|
    # If there's not a node corresponding to this IP, remove it
    remove_a_record(ip: a_record) unless node_ips.include?(a_record)
  end

  info("Finished Cloudflare updater cycle")
end

main ARGV
