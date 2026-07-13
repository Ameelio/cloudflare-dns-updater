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

# Retry policy for read calls.  Writes are not retried in-process; the next
# scheduled cycle reconciles whatever a failed write left behind.
MAX_API_ATTEMPTS = 3
API_RETRY_DELAY_SECONDS = 10

# Keep worst-case runtime (attempts * (open + read) + sleeps, per API) well
# under the CronJob's activeDeadlineSeconds.
HTTP_OPEN_TIMEOUT_SECONDS = 10
HTTP_READ_TIMEOUT_SECONDS = 20

# Network-level failures worth retrying.  Response-shape problems (non-JSON
# bodies, missing keys) are detected after parsing in get_json_array.
TRANSIENT_HTTP_ERRORS = [
  IOError,                 # includes EOFError
  SocketError,
  SystemCallError,         # includes all Errno::*, e.g. ECONNRESET
  Timeout::Error,          # includes Net::OpenTimeout / Net::ReadTimeout
  OpenSSL::SSL::SSLError,
  Net::ProtocolError,
].freeze

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
    open_timeout: HTTP_OPEN_TIMEOUT_SECONDS,
    read_timeout: HTTP_READ_TIMEOUT_SECONDS,
    verify_mode: verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
  ) { |h| h.request(req).body }
end

def parse_json(body)
  JSON.parse(body.to_s)
rescue JSON::ParserError
  nil
end

# GET url and return the `expect` array from its JSON body ('result' for
# Cloudflare, 'items' for the k8s API).  Transient failures -- network errors,
# non-JSON bodies, or an envelope without the array (Cloudflare returns those
# during brief API incidents) -- are retried; if the last attempt still fails,
# log the response and exit non-zero instead of crashing with a backtrace.
# Cloudflare auth failures exit immediately, since a retry cannot fix them.
def get_json_array(url, expect:, bearer:, what:, verify_ssl: true)
  1.upto(MAX_API_ATTEMPTS) do |attempt|
    if attempt > 1
      sleep(API_RETRY_DELAY_SECONDS)
      warning("Retrying #{what} (attempt #{attempt} of #{MAX_API_ATTEMPTS})")
    end

    begin
      resp = http_request(:get, url, bearer: bearer, verify_ssl: verify_ssl)
    rescue *TRANSIENT_HTTP_ERRORS => e
      error("Request for #{what} failed:  #{e.class}: #{e.message}")
      next
    end

    js = parse_json(resp)

    if js.is_a?(Hash) && js['success'] == false
      error("API call for #{what} failed.  The API returned:")
      error(JSON.pretty_unparse(js))

      if js.dig('errors', 0, 'code') == 10000
        error('Cloudflare Authentication failed.  Double check the CF_TOKEN value')
        exit 1
      end

      next
    end

    records = js.is_a?(Hash) ? js[expect] : nil
    return records if records.is_a?(Array)

    error("Response for #{what} is missing the '#{expect}' array:  #{resp.to_s[0, 500].inspect}")
  end

  error("Giving up on #{what} after #{MAX_API_ATTEMPTS} attempts.  Exiting with failure status.")
  exit 1
end

def get_nodes
  # In k8s, the ca cert is mounted at /run/secrets/kubernetes.io/serviceaccount/ca.crt;
  # cert verification is disabled here for parity with prior behavior.
  get_json_array(
    'https://kubernetes.default.svc/api/v1/nodes',
    expect: 'items',
    bearer: k8s_token,
    what: 'the node list from the Kubernetes API',
    verify_ssl: false,
  )
end

def get_node_ips
  # Get list of all nodes from the k8s API, then filter out only the ones that are part of the main or infra pools,
  # and extract the ExternalIP of each node
  get_nodes
    .select { |item| ['main', 'infra'].include?(item['metadata']['labels']['ameelio.org/pool']) }
    .map { |item|
        item['status']['addresses']
          .select { |a| a['type'] == 'ExternalIP' }
          .map { |a| a['address'] }
      }
    .flatten
end

def get_a_records
  get_json_array(
    "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records?name=#{full_hostname}&type=A",
    expect: 'result',
    bearer: cf_token,
    what: "the A records for #{full_hostname}",
  )
end

def relevant_a_records
  get_a_records
    .select { |a_record| a_record['name'] =~ /^#{hostname}/i }
    .map { |a_record| a_record['content'] }
end

def create_a_record(ip:)
  # POST zones/:zone_identifier/dns_records
  info "Creating A record for IP #{ip}"

  resp = http_request(
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

  info("Creation result:  #{resp}")

  parse_json(resp)
rescue *TRANSIENT_HTTP_ERRORS => e
  error("Request to create the A record for IP #{ip} failed:  #{e.class}: #{e.message}")
  nil
end

def remove_a_record(ip:)
  info "Removing A record for IP #{ip}"

  debug "Retrieving ID for A record for IP #{ip}"

  # First get the record's ID
  record = get_json_array(
    "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records?type=A&match=all&content=#{ip}&name=#{full_hostname}",
    expect: 'result',
    bearer: cf_token,
    what: "the A record ID for IP #{ip}",
  ).find { |a_record| a_record['content'] == ip }

  if record.nil?
    warning("No A record found for IP #{ip}; nothing to remove")
    return true
  end

  id = record['id']

  debug "Parsed ID for A record for IP #{ip}.  ID is '#{id}'"

  # DELETE zones/:zone_identifier/dns_records/:identifier
  resp = http_request(
    :delete,
    "https://api.cloudflare.com/client/v4/zones/#{zone_id}/dns_records/#{id}",
    bearer: cf_token,
  )

  info("Removal result:  #{resp}")

  js = parse_json(resp)
  js.is_a?(Hash) && js['success'] == true
rescue *TRANSIENT_HTTP_ERRORS => e
  error("Request to remove the A record for IP #{ip} failed:  #{e.class}: #{e.message}")
  false
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

      # Check that the parsed response contains "success":true
      unless res.is_a?(Hash) && res['success'] == true
        err_msg = "Failed to create A record for IP #{node_ip}.  Cloudflare returned:  #{res.inspect}"
        error(err_msg)
        a_record_creation_errors.push(err_msg)
      end
    end
  end

  if a_record_creation_errors.any?
    error("Errors occurred during Cloudflare update cycle.  Exiting with failure status.")
    exit 1
  end

  a_record_removal_errors = []

  cf_a_records.each do |a_record|
    # If there's not a node corresponding to this IP, remove it
    unless node_ips.include?(a_record)
      unless remove_a_record(ip: a_record)
        err_msg = "Failed to remove A record for IP #{a_record}"
        error(err_msg)
        a_record_removal_errors.push(err_msg)
      end
    end
  end

  if a_record_removal_errors.any?
    error("Errors occurred during Cloudflare update cycle.  Exiting with failure status.")
    exit 1
  end

  info("Finished Cloudflare updater cycle")
end

main ARGV if __FILE__ == $PROGRAM_NAME
