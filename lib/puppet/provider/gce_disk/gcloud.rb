require File.expand_path(File.join(File.dirname(__FILE__), '..', 'gcloud'))

require 'set'
require 'net/http'
require 'uri'
require 'json'
require 'pry'

Puppet::Type.type(:gce_disk).provide(:gcloud, :parent => Puppet::Provider::Gcloud) do
  confine :gcloud_compatible_version => true
  commands :gcloud => "gcloud"

  GCEDISK_NO_REBUILD_PROPERTY_NAMES = [:size]
  GCEDISK_IGNORE_PROPERTY_NAMES = [:ensure]

  mk_resource_methods

  def gcloud_resource_name
    'disks'
  end

  # These arguments are required for both create and destroy
  def gcloud_args
    {:zone => '--zone'}
  end

  def gcloud_optional_create_args
    {:description => '--description',
     :size => '--size',
     :image => '--image'}
  end

  def initialize(value={})# {{{
    super(value)
    @property_flush = {}
	@gce_images = nil
  end# }}}

  def exists?# {{{
	  @property_hash[:ensure] == :present
  end# }}}

  # https://www.googleapis.com/compute/v1/project/<project-id>/aggregated/instances
  # see https://cloud.google.com/compute/docs/reference/latest/instances/aggregatedList
  def get_disk_list# {{{
	disk_list = ((gce_api_GET "aggregated/disks")['items'] || []).
		select {|key, value| value['disks'] }.
		map {|key, value| value['disks']}.
		flatten

	disk_list.each {|disk|
		disk['name'] = last_component(disk['name'])
		disk['zone'] = last_component(disk['zone'])
		disk['type'] = last_component(disk['type'])
		if disk['users']
			disk['users'] = disk['users'].map {|value|
				last_component(value)
			}
		end
	}
  end# }}}

  def self.transform_data(disk_data) # {{{
	  output = {}
	  output[:name] = disk_data['zone'] + "/" + disk_data['name']
	  output[:zone] = disk_data['zone']
	  output[:image] = last_component(disk_data['sourceImage']) if disk_data['sourceImage']
	  output[:users] = disk_data['users']
	  output[:size] = disk_data['sizeGb']

#	  if not disk_data['metadata']['items'].nil?
#		  output[:metadata] = {}
#		  disk_data['metadata']['items'].each do |item|
#			  output[:metadata][item['key']] = item['value']
#		  end
#	  end
#	  if disk_data['status'] == 'TERMINATED'
#		byebug
#	  end

# CREATING, FAILED, READY, RESTORING.
	  output[:ensure] = case disk_data['status'] 
						when 'READY'
							:present
						else
							:absent
						end
	  Puppet.debug "gce_disk properties: #{output.inspect}"
	  output
  end# }}}

  def self.instances# {{{
#	  byebug
	  class_instance = Puppet::Type::Gce_disk::ProviderGcloud.new
	  disks = class_instance.get_disk_list
	  disks.map do |value|
		  new(transform_data(value))
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

  def self.normalize_name(hostname)# {{{
	  _,name = hostname.split('/')
	  name
  end# }}}

  def size=(value)# {{{
	  @property_flush[:size] = value
  end# }}}

  def image=(value)# {{{
	  @property_flush[:image] = value
  end# }}}

  def set_disk_properties# {{{
	no_rebuild_flush = {}
	require_rebuild_flush = {}

	#byebug

    if @property_flush[:ensure] == :absent
		delete_disk
        return
    end

	# sort flushed properties in categories - no restart, needs restart, needs rebuild
	@property_flush.each {|key, value|
		if GCEDISK_IGNORE_PROPERTY_NAMES.member? key
			next
		end
		if GCEDISK_NO_REBUILD_PROPERTY_NAMES.member? key
			no_rebuild_flush[key] = value
		else
			require_rebuild_flush[key] = value
		end
	}

	# XXX: may be check disk sizes later and allow gworing without confirmation
	if @property_hash[:ensure] == :present and
		no_rebuild_flush.length > 0 and
		no_rebuild_flush[:size] and
		not [:resize, :delete_instance].member? resource[:force_updates]
      raise Puppet::Error, "Disk resize requires explicit permission, set force_updates => delete_instance or resize."
	end

	if @property_hash[:ensure] == :present and
		require_rebuild_flush.length > 0 and
		not [:delete_instance].member? resource[:force_updates]
      raise Puppet::Error, "Parameters requiring disk rebuild explicit permission, set force_updates => delete_instance."
	end

	# if we are going to rebuild disk, do not flush
	# changes before that, they are going to be applyed anyway
	# during rebuild
	if require_rebuild_flush.length == 0
		# use later for setLabel method
		flush_disk_properties no_rebuild_flush
	end

	# properties requiring restart
	flush_disk_properties require_rebuild_flush
  end# }}}

  def flush# {{{
	  if @property_flush.length > 0
		  set_disk_properties
	  end
  end# }}}

  def flush_disk_properties(properties)
	  disk = last_component @property_hash[:name]
	  zone = last_component @property_hash[:zone]

	  if properties[:image_regexp]
		  #byebug
		  properties[:image] = image_response['items'].
			  select {|v| v['name'].match(Regexp.new properties[:image_regexp])}.
			  map {|v| v['name']}.
			  sort.last
	  end

	  if properties[:image]
		  #byebug
		  # XXX: extremely bad hack to stop instance BEFORE gce_instance is ever evailable
		  # we rely of gce_instance to recreate instance from new image
		  # there is no way in Puppet to have access to gce_instance when this
		  # piece of code is executing, it is not even instantiated yet
		  if @property_hash[:users]
			  host = @property_hash[:users][0]
			  # we assume host is in the same zone as disk
			  res = gce_api_DELETE "zones/#{zone}/instances/#{host}"
			  gce_WAIT res, call_by: 'gce_disk/delete instance'
		  end
		  res = gce_api_DELETE "zones/#{zone}/disks/#{disk}"
		  gce_WAIT res, call_by: 'gce_disk/delete disk'

		  create
	  end

	  if properties[:size]
		  #byebug
		  data = { 
			  :sizeGb => properties[:size],
		  }
		  res = gce_api_POST "zones/#{zone}/disks/#{disk}/resize", data
		  gce_WAIT res, call_by: 'gce_disk/resize'
	  end
  end
end
