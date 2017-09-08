require File.expand_path(File.join(File.dirname(__FILE__), '..', 'gcloud'))

# debugging
# /opt/puppetlabs/puppet/bin/gem install pry byebug pry-byebug

require 'set'
require 'net/http'
require 'uri'
require 'json'

Puppet::Type.type(:gce_instance_template_generator).provide(:gcloud, :parent => Puppet::Provider::Gcloud) do
  confine :gcloud_compatible_version => true
  commands :gcloud => "gcloud"

  GCE_INST_TMPL_GEN_NO_RESTART_PROPERTY_NAMES = [:tags, :metadata]
  GCE_INST_TMPL_GEN_RESTART_PROPERTY_NAMES = [:machine_type]
  GCE_INST_TMPL_GEN_IGNORE_PROPERTY_NAMES = [:ensure]

  mk_resource_methods

  def build_gcloud_args(action)
	  ['compute', gcloud_resource_name, action, resource[:template_name] ] + build_gcloud_flags(gcloud_args)
  end

  def gcloud_resource_name# {{{
    'instance-templates'
  end# }}}

#  # These arguments are required for both create and destroy
#  def gcloud_args# {{{
#	  #    {}
##    {:zone => '--zone'}
#  end# }}}
  def gcloud_optional_create_args# {{{
    {:description        => '--description',
#     :address            => '--address',
     :image              => '--image',
     :disk_type          => '--boot-disk-type',
     :custom_memory_size => '--custom-memory',
     :custom_cpu_count   => '--custom-cpu',
     :machine_type       => '--machine-type',
     :network            => '--network',
     :subnet 			 => '--subnet',
     :region 			 => '--region',
#     :maintenance_policy => '--maintenance-policy',
#     :scopes             => '--scopes',
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
	byebug
    @property_flush[:ensure] = :present
  end# }}}

  def destroy# {{{
	  byebug
    @property_flush[:ensure] = :absent
  end# }}}

  def stop# {{{
	  byebug
    @property_flush[:ensure] = :terminated
  end# }}}

  def create# {{{
	resource[:template_name] = resource[:name] + "-" + Time.now.to_i.to_s
    args = build_gcloud_args('create') + build_gcloud_flags(gcloud_optional_create_args)
    append_disk_size(args, resource)
    append_can_ip_forward_args(args, resource)
    append_custom_extensions(args, resource)
    append_metadata_args(args, resource)
#    append_startup_script_args(args, resource)
    gcloud(*args)
	@just_created = true
  end# }}}

  def append_can_ip_forward_args(args, resource)# {{{
    args << '--can-ip-forward' if resource[:can_ip_forward]
  end# }}}

  def append_custom_extensions(args, resource)# {{{
    args << '--custom-extensions ' if resource[:custom_extensions]
  end# }}}

  def append_disk_size(args, resource)# {{{
	  if resource[:disk_size]
		  args << '--boot-disk-size' 
		  args << "#{resource[:disk_size]}GB"
	  end
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
#      puppet_metadata.each do |k, v|
#        metadata_args << "#{k}=#{resource[v]}" if resource[v]
#      end
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

  def build_gcloud_ssh_startup_script_check_args# {{{
    ['compute', 'ssh', resource[:name]] + build_gcloud_flags(gcloud_args) + ['--command', 'tail /var/log/startupscript.log -n 1']
  end# }}}

  def has_metadata_args?(resource)# {{{
    resource[:metadata] or (puppet_metadata.values.map{ |v| resource[v] }.any?)
  end# }}}

  # https://www.googleapis.com/compute/v1/project/<project-id>/aggregated/instances
  # see https://cloud.google.com/compute/docs/reference/latest/instances/aggregatedList
  def get_instance_template_meta_list# {{{
	full_list = (gce_api_GET "global/instanceTemplates", :beta)['items'] || []

	def find_latest(acc, template)
		name = template['name']
		matches = name.match(/^(.*)-(\d+)$/)

		if matches
			short_name = matches[1]
			ts = matches[2]
			if !acc[short_name] || (acc[short_name][:ts] < ts)
				acc[short_name] = {:value => template, :ts => ts}
			end
		end

		acc
	end

	def put_values_inside(iteration_value) 
		key, value = iteration_value
		result = value[:value]
		result[:ts] = value[:ts]
		result[:key] = key
		result
	end

	full_list.reduce({}, &method(:find_latest)).
		map(&method(:put_values_inside))
	
#
#		select {|key, value| value['instances'] }.
#		map {|key, value| value['instances']}.
#		flatten
#
#	instances_list.each {|host|
#		host['machineType'] = last_component(host['machineType'])
#		host['name'] = last_component(host['name'])
#		host['zone'] = last_component(host['zone'])
#	}
  end# }}}

  def exists?# {{{
	  @property_hash[:ensure] == :present
  end# }}}

  def self.transform_data(data) # {{{
	  template_data = data['properties']
	  output = {}
#	  byebug
#	  pp template_data
	  output[:name] = data[:key]
	  output[:template_name] = data['name']
	  output[:description] = data['description']

	  output[:machine_type] = template_data['machineType']

	  if matches = template_data['machineType'].match(/^custom-(\d+)-(\d+)$/)
		  output[:custom_cpu_count] = matches[1]
		  output[:custom_memory_size] = matches[2].to_f / 1024
		  output[:custom_extensions] = false
		  output.delete(:machine_type)
	  end

	  if matches = template_data['machineType'].match(/^custom-(\d+)-(\d+)-ext$/)
		  output[:custom_cpu_count] = matches[1]
		  output[:custom_memory_size] = matches[2].to_f / 1024
		  output[:custom_extensions] = true
		  output.delete(:machine_type)
	  end

	  if template_data['canIpForward'] == 'true'
		  output[:can_ip_forward] = true
	  end
	  output[:tags] = template_data['tags']['items']
#	  output[:tags_fingerprint] = template_data['tags']['fingerprint']
#	  output[:metadata_fingerprint] = template_data['metadata']['fingerprint']

	  if not template_data['metadata']['items'].nil?
		  output[:metadata] = {}
		  template_data['metadata']['items'].each do |item|
			  output[:metadata][item['key']] = item['value']
		  end
	  end

	  if template_data['disks'] && template_data['disks'][0]
		  disk_params = template_data['disks'][0]['initializeParams']
		  output[:disk_size] = disk_params['diskSizeGb']
		  output[:disk_type] = disk_params['diskType']
		  output[:image] = last_component disk_params['sourceImage']
	  end

	  if template_data['networkInterfaces'].length > 0 
		  net = template_data['networkInterfaces'][0]
		  if net['subnetwork']
			  output[:subnet] = last_component net['subnetwork']
			  output[:region] = net['subnetwork'].split('/')[-3]
		  else
			  if net['network']
				  output[:network] = last_component net['network']
			  end
		  end
	  end

#	  if template_data['status'] == 'TERMINATED'
#		byebug
#	  end

#	  output[:ensure] = case template_data['status'] 
#						when 'RUNNING'
#							:present
#						when 'TERMINATED'
#							:terminated
#						else
#							:absent
#						end
	  Puppet.debug "gce_instance properties: #{output.inspect}"
	  output
  end# }}}

  def self.instances# {{{
	  class_instance = Puppet::Type::Gce_instance_template_generator::ProviderGcloud.new
	  hosts = class_instance.get_instance_template_meta_list
	  hosts.map do |instance|
		  new(transform_data(instance))
	  end
  end# }}}

  def self.prefetch(resources)# {{{
	  all_instances = {}
	  instances.each do |prov|
		  resource_name = last_component prov.name
		  all_instances[resource_name] = prov
	  end

	  resources.each do |resource_name, resource|
		  if all_instances[resource_name]
			  resource.provider = all_instances[resource_name]
		  end

		  if resource[:image_regexp] && !resource[:image]
			  # fetch list of images and use last matching to regexp as our target image
			  available_images = resource.provider.get_gce_private_image_list.grep(Regexp.new resource[:image_regexp])
			  resource[:image] = available_images.last
		  end
	  end
  end# }}}

  def custom_cpu_count=(value) @property_flush[:custom_cpu_count] = value end
  def custom_memory_size=(value) @property_flush[:custom_memory_size] = value end
  def disk_size=(value) @property_flush[:disk_size] = value end
  def disk_type=(value) @property_flush[:disk_type] = value end
  def image=(value) @property_flush[:image] = value end
  def machine_type=(value) @property_flush[:machine_type] = value end
  def metadata=(value) @property_flush[:metadata] = value end
  def tags=(value) @property_flush[:tags] = value end

  #  curl -u "oauth2accesstoken:$(gcloud auth print-access-token)" https://eu.gcr.io/v2/swarmcloudtest/goverlord/tags/list

  def set_instance_template_properties# {{{
	  # if we got here, it means some of parameters changed
	  # it does not matter which one - we just need to create another template
	  # and generate refresh event (automatically)
	  #
	  #	XXX may be we should have ensure property and skip this step when
	  #	it is set to :absent
#	byebug
	  create
	return
  end# }}}

  def flush# {{{
	  set_instance_template_properties
  end# }}}

  def bring_online
	  @property_hash[:ensure] = self.ensure
	  @property_flush[:ensure] = :present
	  pp self.ensure
	  return
  end

  def refresh
	  return
  end
end
