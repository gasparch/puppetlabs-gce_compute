require File.expand_path(File.join(File.dirname(__FILE__), '..', 'gcloud'))

# debugging
# /opt/puppetlabs/puppet/bin/gem install pry byebug pry-byebug

require 'set'
require 'net/http'
require 'uri'
require 'json'

Puppet::Type.type(:gce_instance).provide(:gcloud, :parent => Puppet::Provider::Gcloud) do
  confine :gcloud_compatible_version => true
  commands :gcloud => "gcloud"

  BLOCK_FOR_STARTUP_SCRIPT_INTERVAL = 10
  GCE_INST_NO_RESTART_PROPERTY_NAMES = [:tags, :metadata]
  GCE_INST_RESTART_PROPERTY_NAMES = [:machine_type]
  GCE_INST_IGNORE_PROPERTY_NAMES = [:ensure]

  mk_resource_methods

  def gcloud_resource_name# {{{
    'instances'
  end# }}}

  # These arguments are required for both create and destroy
  def gcloud_args# {{{
    {:zone => '--zone'}
  end# }}}

  def gcloud_optional_create_args# {{{
    {:description        => '--description',
     :address            => '--address',
     :image              => '--image',
     :machine_type       => '--machine-type',
     :network            => '--network',
     :maintenance_policy => '--maintenance-policy',
     :scopes             => '--scopes',
     :tags               => '--tags'}
  end# }}}

  def puppet_metadata# {{{
    {'puppet_master'       => :puppet_master,
     'puppet_service'      => :puppet_service,
     'puppet_modules'      => :puppet_modules,
     'puppet_module_repos' => :puppet_module_repos}
  end# }}}

  def initialize(value={})# {{{
    super(value)
    @property_flush = {}
	@just_created = false
  end# }}}

  def start# {{{
    @property_flush[:ensure] = :present
  end# }}}

  def destroy# {{{
    @property_flush[:ensure] = :absent
  end# }}}

  def stop# {{{
    @property_flush[:ensure] = :terminated
  end# }}}

  def create# {{{
    args = build_gcloud_args('create') + build_gcloud_flags(gcloud_optional_create_args)
    append_can_ip_forward_args(args, resource)
    append_boot_disk_args(args, resource)
    append_metadata_args(args, resource)
    append_startup_script_args(args, resource)
    gcloud(*args)
    block_for_startup_script(resource)

	@just_created = true
  end# }}}

  def append_can_ip_forward_args(args, resource)# {{{
    args << '--can-ip-forward' if resource[:can_ip_forward]
  end# }}}

  def append_boot_disk_args(args, resource)# {{{
	#  resource[:boot_disk].type == "Gce_disk"
    if resource[:boot_disk]
      args << '--disk'
      args << "name=#{resource[:boot_disk]},boot=yes"
    end
  end# }}}

  def append_metadata_args(args, resource)# {{{
    if has_metadata_args?(resource)
      metadata_args = []
      if resource[:metadata]
        resource[:metadata].each do |k, v|
          metadata_args << "#{k}=#{v}"
        end
      end
      puppet_metadata.each do |k, v|
        metadata_args << "#{k}=#{resource[v]}" if resource[v]
      end
      args << '--metadata'
      args << metadata_args.join(',')
    end
  end# }}}

  def append_startup_script_args(args, resource)# {{{
    if resource[:startup_script] or resource[:puppet_manifest]
      metadata_args = []
      if resource[:startup_script]
        startup_script_file = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', '..', 'files', "#{resource[:startup_script]}"))
        metadata_args << "startup-script=#{startup_script_file}"
      end
      if resource[:puppet_manifest]
        puppet_manifest_file = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', '..', 'files', "#{resource[:puppet_manifest]}"))
        metadata_args << "puppet_manifest=#{puppet_manifest_file}"
      end
      args << '--metadata-from-file'
      args << metadata_args.join(',')
    end
  end# }}}

  def block_for_startup_script(resource)# {{{
    if resource[:block_for_startup_script]
      begin
        # NOTE if startup_script_timeout is nil, the block will run without timing out
        Timeout::timeout(resource[:startup_script_timeout]) do
          loop do
            break if gcloud(*build_gcloud_ssh_startup_script_check_args) =~ /Finished running startup script/
            sleep BLOCK_FOR_STARTUP_SCRIPT_INTERVAL
          end
        end
      rescue Timeout::Error
        fail('Timed out waiting for bootstrap script to execute')
      end
    end
  end# }}}

  def build_gcloud_ssh_startup_script_check_args# {{{
    ['compute', 'ssh', resource[:name]] + build_gcloud_flags(gcloud_args) + ['--command', 'tail /var/log/startupscript.log -n 1']
  end# }}}

  def has_metadata_args?(resource)# {{{
    resource[:metadata] or (puppet_metadata.values.map{ |v| resource[v] }.any?)
  end# }}}

  # https://www.googleapis.com/compute/v1/project/<project-id>/aggregated/instances
  # see https://cloud.google.com/compute/docs/reference/latest/instances/aggregatedList
  def get_instance_list# {{{
	instances_list = (gce_api_GET "aggregated/instances")['items'].
		select {|key, value| value['instances'] }.
		map {|key, value| value['instances']}.
		flatten

	instances_list.each {|host|
		host['machineType'] = last_component(host['machineType'])
		host['name'] = last_component(host['name'])
		host['zone'] = last_component(host['zone'])
	}
  end# }}}

  def exists?# {{{
	  @property_hash[:ensure] == :present
  end# }}}

  def self.transform_data(host_data) # {{{
	  output = {}
	  output[:name] = host_data['zone'] + "/" + host_data['name']
	  output[:zone] = host_data['zone']
	  output[:machine_type] = host_data['machineType']
	  output[:tags] = host_data['tags']['items']
	  output[:tags_fingerprint] = host_data['tags']['fingerprint']

	  output[:metadata_fingerprint] = host_data['metadata']['fingerprint']

	  if not host_data['metadata']['items'].nil?
		  output[:metadata] = {}
		  host_data['metadata']['items'].each do |item|
			  output[:metadata][item['key']] = item['value']
		  end
	  end

	  output[:ensure] = case host_data['status'] 
						when 'RUNNING'
							:present
						when 'TERMINATED'
							:terminated
						else
							:absent
						end
	  Puppet.debug "gce_instance properties: #{output.inspect}"
	  output
  end# }}}

  def self.instances# {{{
#	  byebug
	  class_instance = Puppet::Type::Gce_instance::ProviderGcloud.new
	  hosts = class_instance.get_instance_list
	  hosts.map do |instance|
		  new(transform_data(instance))
	  end
  end# }}}

  def self.prefetch(resources)# {{{
	  instances.each do |prov|
		  resource_name = last_component prov.name

		  if resource = resources[resource_name]
			  resource.provider = prov
		  end
	  end
  end# }}}

  def tags=(value)# {{{
	  @property_flush[:tags] = value
  end# }}}

  def metadata=(value)# {{{
	  @property_flush[:metadata] = value
  end# }}}

  def machine_type=(value)# {{{
	  @property_flush[:machine_type] = value
  end# }}}

  #  curl -u "oauth2accesstoken:$(gcloud auth print-access-token)" https://eu.gcr.io/v2/swarmcloudtest/goverlord/tags/list

  def set_instance_properties# {{{
	no_restart_flush = {}
	require_restart_flush = {}
	require_rebuild_flush = {}

#	byebug

    if @property_flush[:ensure] == :absent
		delete_instance
        return
    end

	if @property_hash[:ensure] == :absent && @property_flush[:ensure] == :present
		create
		return
	end

    if @property_flush[:ensure] == :terminated
		stop_instance
    end

	# sort flushed properties in categories - no restart, needs restart, needs rebuild
	@property_flush.each {|key, value|
		if GCE_INST_IGNORE_PROPERTY_NAMES.member? key
			next
		end
		if GCE_INST_NO_RESTART_PROPERTY_NAMES.member? key
			no_restart_flush[key] = value
		elsif GCE_INST_RESTART_PROPERTY_NAMES.member? key
			require_restart_flush[key] = value
		else
			require_rebuild_flush[key] = value
		end
	}

#	byebug
	if @property_hash[:ensure] == :present and
		require_restart_flush.length > 0 and
		not [:rebuild, :restart].member? resource[:force_updates]
      raise Puppet::Error, "Parameters requiring running instance restart need explicit permission, set force_updates => restart or rebuild."
	end

	if require_rebuild_flush.length > 0 
		if @property_hash[:ensure] == :terminated
			raise Puppet::Error, "Parameters requiring instance deletion/rebuild need instance to be either present (running) or absent (non existent), now it is stopped."
		end

		if not [:rebuild].member? resource[:force_updates]
			raise Puppet::Error, "Parameters requiring instance deletion/rebuild need explicit permission, set force_updates => rebuild."
		end
	end

	flush_instance_properties no_restart_flush

	if require_restart_flush.length > 0
		# if host if running now - stop it and make changes
		if @property_hash[:ensure] == :present
			stop_instance

			# emulate host start request
			@property_hash[:ensure] = :terminated
			@property_flush[:ensure] = :present
		end
#		byebug
		flush_instance_properties require_restart_flush
	end

	if @property_hash[:ensure] == :terminated && @property_flush[:ensure] == :present
		start_instance
	end
  end# }}}

  def flush# {{{
#	  byebug
	  set_instance_properties
  end# }}}

  def flush_instance_properties(properties)# {{{
	  host = last_component @property_hash[:name]
	  zone = last_component @property_hash[:zone]

	  if properties[:tags]
		  data = { 
			  :items => properties[:tags],
			  :fingerprint => @property_hash[:tags_fingerprint]
		  }
		  res = gce_api_POST "zones/#{zone}/instances/#{host}/setTags", data
		  gce_WAIT res
	  end

	  if properties[:metadata]
		  data = {
			  :kind => "compute#metadata",
			  :items => properties[:metadata].map {|k,v| {:key => k, :value => v}},
			  :fingerprint => @property_hash[:metadata_fingerprint]
		  }
		  res = gce_api_POST "zones/#{zone}/instances/#{host}/setMetadata", data
		  gce_WAIT res
	  end

	  if properties[:machine_type]
		  data = {
			  :machineType => "zones/#{zone}/machineTypes/#{properties[:machine_type]}"
		  }
		  res = gce_api_POST "zones/#{zone}/instances/#{host}/setMachineType", data
		  gce_WAIT res
	  end
  end# }}}

  def stop_instance# {{{
	  host = last_component @property_hash[:name]
	  zone = last_component @property_hash[:zone]

	  res = gce_api_POST "zones/#{zone}/instances/#{host}/stop"
	  gce_WAIT res, timeout: 120
  end# }}}

  def delete_instance# {{{
	  host = last_component @property_hash[:name]
	  zone = last_component @property_hash[:zone]

	  res = gce_api_DELETE "zones/#{zone}/instances/#{host}"
	  gce_WAIT res
  end# }}}

  def start_instance# {{{
	  host = last_component @property_hash[:name]
	  zone = last_component @property_hash[:zone]

	  res = gce_api_POST "zones/#{zone}/instances/#{host}/start"
	  gce_WAIT res, timeout: 120
  end# }}}

  def bring_online
	  @property_hash[:ensure] = self.ensure
	  @property_flush[:ensure] = :present
  end

  def refresh
	  if not @just_created
		  if self.ensure == :absent
			  create
			  debug "gce_instance refresh: rebuilding instance"
		  else
			  delete_instance
			  start_instance
		  end
	  end
  end
end
