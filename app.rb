#!/usr/bin/env ruby

# PUT zones/:zone_identifier/dns_records/:identifier

require 'http'
require 'json'

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

def get_nodes
  # In k8s, the ca cert is mounted here:
  # /run/secrets/kubernetes.io/serviceaccount/ca.crt

  # In dev, ca cert verification can be disabled
  ctx = OpenSSL::SSL::SSLContext.new
  ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
  #ctx.ca_file = '/run/secrets/kubernetes.io/serviceaccount/ca.crt'

  resp = HTTP
    .auth("Bearer #{k8s_token}")
    .headers(accept: 'application/json')
    .headers('content-type': 'application/json')
    .get("https://kubernetes.default.svc/api/v1/nodes", ssl_context: ctx)
    .body

  # This object is very large, so comment out for now
  # debug("Retrieved nodes:  #{resp}")

  JSON.parse(resp)
end

def get_node_ips
  # Get list of all nodes from the k8s API, then filter out only the ones that are part of the main pool,
  # and extract the ExternalIP of each node
  get_nodes()['items']
    .select { |item| item['metadata']['labels']['ameelio.org/pool'] == 'main' }
    .map { |item|
        item['status']['addresses']
          .select { |a| a['type'] == 'ExternalIP' }
          .map { |a| a['address'] }
      }
    .flatten
end

def get_a_records
  resp = HTTP
    .auth("Bearer #{cf_token}")
    .headers(accept: 'application/json')
    .headers('content-type': 'application/json')
    .get("https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records?name=#{full_hostname}&type=A")
    .body

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

  result = HTTP
    .auth("Bearer #{cf_token}")
    .headers(accept: 'application/json')
    .headers('content-type': 'application/json')
    .post("https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records", json: {
      type: "A",
      name: hostname,
      content: ip,
      ttl: 360,
      proxied: false
    })
    .body

  info("Creation result:  #{result}")

  result
end

def remove_a_record(ip:)
  info "Removing A record for IP #{ip}"

  debug "Retrieving ID for A record for IP #{ip}"

  # First get the record's ID
  # TODO:  Limit search to cvh-staging.ameelio.org
  resp = HTTP
    .auth("Bearer #{cf_token}")
    .headers(accept: 'application/json')
    .headers('content-type': 'application/json')
    .get("https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records?type=A&match=all&content=#{ip}&name=#{full_hostname}")
    .body

  debug "Parsing ID for A record for IP #{ip}"

  record = JSON.parse(resp)['result']
    .select { |a_record| a_record['content'] == ip }
    .first
  id = record['id']

  debug "Parsed ID for A record for IP #{ip}.  ID is '#{id}'"

  # DELETE zones/:zone_identifier/dns_records/:identifier
  result = HTTP
    .auth("Bearer #{cf_token}")
    .headers(accept: 'application/json')
    .headers('content-type': 'application/json')
    .delete("https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records/#{id}")
    .body

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
