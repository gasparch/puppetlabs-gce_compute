require File.expand_path(File.join(File.dirname(__FILE__), '..', 'gcloud'))

require 'set'
require 'net/http'
require 'uri'
require 'json'
require 'pry'

Puppet::Type.type(:gce_projectmetadata).provide(:gcloud, :parent => Puppet::Provider::Gcloud) do
#  confine :gcloud_compatible_version => true
  commands :gcloud => "gcloud"

  mk_resource_methods

  def initialize(value={})# {{{
    super(value)
    @property_flush = {}
  end# }}}

#  def exists?# {{{
#	  @property_hash[:ensure] == :present
#  end# }}}

  # https://www.googleapis.com/compute/v1/project/<project-id>/aggregated/instances
  # see https://cloud.google.com/compute/docs/reference/latest/instances/aggregatedList
  def get_variable_list# {{{
	[ (gce_api_GET "")['commonInstanceMetadata'] ]
  end# }}}

  def self.transform_data(data) # {{{
	  output = {}
	  output[:name] = 'default'
	  output[:metadata_fingerprint] = data['fingerprint']

	  if not data['items'].nil?
		  output[:metadata] = {}
		  data['items'].each do |item|
			  output[:metadata][item['key']] = item['value']
		  end
	  end

	  Puppet.debug "gce_projectmetadata properties: #{output.inspect}"
	  output
  end# }}}

  def self.instances# {{{
#	  byebug
	  class_instance = Puppet::Type::Gce_projectmetadata::ProviderGcloud.new
	  disks = class_instance.get_variable_list
	  disks.map do |value|
		  new(transform_data(value))
	  end
  end# }}}

  def self.prefetch(resources)# {{{
	  instances.each do |prov|
		  resource_name = prov.name

		  if resource = resources[resource_name]
			  # if we do not want to namage sshKeys, also do not dump it from cloud
			  # backup sshKeys in separate variable and insert them
			  # back into request if necessary
			  prov.ssh_key = prov.metadata["sshKeys"]
			  if !resource[:allow_sshkeys_override] 
				  prov.metadata.delete "sshKeys"
			  end
			  resource.provider = prov
		  end
	  end
  end# }}}

  def ssh_key=(value)
	  @ssh_keys = value
  end

  def metadata=(value)# {{{
	  @property_flush[:metadata] = value
  end# }}}

  def set_project_metadata# {{{
	output = @property_hash[:metadata].clone
	output[:sshKeys] = @ssh_keys

	@property_flush[:metadata].each {|k,v| 
		if k == 'sshKeys' && !resource[:allow_sshkeys_override]
			next
		end

		if v.is_a?(Hash) 
			if resource[:convert_hash_to_json] 
				output[k] = v.to_json
			else
				raise Puppet::Error, "Cannot convert #{k} => #{v} to string, set convert_hash_to_json"
			end
		else
			output[k] = v
		end
	}

	data = { 
		:kind => "compute#metadata",
		:items => output.map {|k,v| {:key => k, :value => v}},
		:fingerprint => @property_hash[:metadata_fingerprint]
	}
	res = gce_api_POST "setCommonInstanceMetadata", data
	gce_WAIT res
  end# }}}

  def flush# {{{
	  if @property_flush.length > 0
		  set_project_metadata
	  end
  end# }}}
end
