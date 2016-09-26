require File.expand_path(File.join(File.dirname(__FILE__), '..', 'gcloud'))

# debugging
# /opt/puppetlabs/puppet/bin/gem install pry byebug pry-byebug

require 'set'
require 'net/http'
require 'uri'
require 'json'

Puppet::Type.type(:gce_managed_instance_group).provide(:gcloud, :parent => Puppet::Provider::Gcloud) do
  confine :gcloud_compatible_version => true
  commands :gcloud => "gcloud"

  IGNORE_PROPERTY_NAMES = [:ensure]
  GCE_MNGD_GROUP_NO_RESTART_PROPERTY_NAMES = [:instance_template, :target_pools]

  GCE_MNGD_GROUP_AUTOSCALER_PROPERTY_NAMES = [:size, :max_num_replicas, :min_num_replicas, :target_cpu_utilization, :autoscaling, :cool_down_period]

#  AUTOHEALER_PROPERTY_NAMES = []
  GCE_MNGD_GROUP_REBUILD_PROPERTY_NAMES = [:zone, :region, :base_instance_name]

  mk_resource_methods

  def gcloud_resource_name# {{{
    'instance-groups'
  end# }}}

  def gcloud_extra_resource_name# {{{
    'managed'
  end# }}}

#  # These arguments are required for both create and destroy
#  def gcloud_args# {{{
#	  #    {}
##    {:zone => '--zone'}
#  end# }}}
  def gcloud_optional_create_args# {{{
    {
     #     :address            => '--address',
     :base_instance_name => '--base-instance-name',
     :target_pools  		 => '--target-pool',
     :zone				       => '--zone',
     :region	      		 => '--region',
     :size 				       => '--size',
     :instance_template  => '--template' 
    }
  end# }}}

  def initialize(value={})# {{{
    super(value)
    @property_flush = {}
    @autoscalers_hash = false
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

  def build_gcloud_args(action, use_beta=false)
    if use_beta
      ['beta', 'compute', gcloud_resource_name, gcloud_extra_resource_name, action, resource[:name] ] + build_gcloud_flags(gcloud_args)
    else
      ['compute', gcloud_resource_name, gcloud_extra_resource_name, action, resource[:name] ] + build_gcloud_flags(gcloud_args)
    end
  end

  def create# {{{
    use_beta = !resource[:region].nil?
    args = build_gcloud_args('create', use_beta) + build_gcloud_flags(gcloud_optional_create_args)
    gcloud(*args)
    @just_created = true
  end# }}}


  def get_instance_group_managers_list name=nil
    if !@gce_instance_group_managers
      @gce_instance_group_managers = (gce_api_GET "aggregated/instanceGroupManagers")['items'].
        select {|key, value| value['instanceGroupManagers'] }.
        each {|key,value| value['instanceGroupManagers'].each {|v| v[:key] = key} }.
        map {|key, value| value['instanceGroupManagers'] }.
        flatten
    end
    if name.nil?
      @gce_instance_group_managers
    else
      @gce_instance_group_managers.select {|v|
        v['name'] == name
      }.first
    end
  end

  def get_autoscalers_info_hash name# {{{
    if !@autoscalers_hash 
      @autoscalers_hash = {}
      (gce_api_GET "aggregated/autoscalers")['items'].
        select {|key, value| value['autoscalers'] }.
        map {|key, value| value['autoscalers'] }.
        flatten.
        each {|v| @autoscalers_hash[v['target']] = v}
    end
    @autoscalers_hash[name]
  end# }}}

  # https://www.googleapis.com/compute/v1/project/<project-id>/aggregated/instances
  # see https://cloud.google.com/compute/docs/reference/latest/instances/aggregatedList
  def get_group_list # {{{
    group_list = get_instance_group_managers_list 
#    (gce_api_GET "aggregated/instanceGroupManagers")['items'].
#      select {|key, value| value['instanceGroupManagers'] }.
#      each {|key,value| value['instanceGroupManagers'].each {|v| v[:key] = key} }.
#      map {|key, value| value['instanceGroupManagers'] }.
#      flatten

    group_list.each {|group|
      # silent assumption that there is just exactly one autoscaler for each
      # target group
      if autoscaler = get_autoscalers_info_hash( group['selfLink'] )
        group[:autoscaler] = autoscaler['autoscalingPolicy']
      end

      if group[:key].match(/^zones/)
        group[:zone] = last_component(group[:key])
      else
        group[:region] = last_component(group[:key])
      end

      group['instanceTemplate'] = last_component(group['instanceTemplate'])
      group['instanceGroup'] = last_component(group['instanceGroup'])
    }
  end# }}}

  def exists?# {{{
	  @property_hash[:ensure] == :present
  end# }}}

  def self.transform_data(data) # {{{
    output = {}
    #	  byebug
    #	  pp data
    if data[:zone]
      output[:name] = data[:zone] + "/" + data['name']
      output[:zone] = data[:zone]
    else
      output[:name] = data[:region] + "/" + data['name']
      output[:region] = data[:region]
    end

    output[:ensure] = :present
    output[:instance_template] = data['instanceTemplate']
    output[:base_instance_name] = data['baseInstanceName']

    if data['targetPools']
      output[:target_pools] = data['targetPools'].map {|v| last_component v}
    end

    if data['targetSize']
      output[:size] = data['targetSize']
    end

    if data[:autoscaler]
      autoscaler = data[:autoscaler]
      output[:min_num_replicas] = autoscaler['minNumReplicas']
      output[:max_num_replicas] = autoscaler['maxNumReplicas']
      output[:cool_down_period] = autoscaler['coolDownPeriodSec']

      if autoscaler['cpuUtilization']
        output[:autoscaling] = :cpu
        output[:target_cpu_utilization] =
          (autoscaler['cpuUtilization']['utilizationTarget'] * 100).to_i
      end
    end

    if output[:autoscaling].nil?
      output[:autoscaling] = :false
    end

    Puppet.debug "gce_managed_instance_group properties: #{output.inspect}"
    output
  end# }}}

  def self.instances# {{{
	  class_instance = Puppet::Type::Gce_managed_instance_group::ProviderGcloud.new
	  groups = class_instance.get_group_list
	  groups.map do |instance|
		  new(transform_data(instance))
	  end
  end# }}}


  def self.prefetch(resources)
    all_instances = {}
    instances.each do |prov|
      resource_name = last_component prov.name
      all_instances[resource_name] = prov
    end

    resources.each do |resource_name, resource|
      if all_instances[resource_name]
        resource.provider = all_instances[resource_name]
      end

      resource.provider.fill_resource_instance_template resource
    end
  end

  def fill_resource_instance_template res, refetch: false
      if res[:instance_template_regexp] && !res[:instance_template]
        # fetch list of images and use last matching to regexp as our target image
        available_images = res.provider.get_gce_template_list(nil, refetch).grep(Regexp.new res[:instance_template_regexp])
        if !available_images.last.nil?
          res[:instance_template] = available_images.last
        end
      end
  end

  def base_instance_name=(value) @property_flush[:base_instance_name] = value end
  def instance_template_regexp=(value) @property_flush[:instance_template_regexp] = value end
  def instance_template=(value) @property_flush[:instance_template] = value end
  def min_num_replicas=(value) @property_flush[:min_num_replicas] = value end
  def max_num_replicas=(value) @property_flush[:max_num_replicas] = value end
  def autoscaling=(value) @property_flush[:autoscaling] = value end
  def target_cpu_utilization=(value) @property_flush[:target_cpu_utilization] = value end
  def cool_down_period=(value) @property_flush[:cool_down_period] = value end
  def size=(value) @property_flush[:size] = value end
  def zone=(value) @property_flush[:zone] = value end
  def target_pools=(value) @property_flush[:target_pools] = value end

  def set_instance_properties# {{{
    # if we got here, it means some of parameters changed
    # it does not matter which one - we just need to create another template
    # and generate refresh event (automatically)
    no_restart_flush = {}
    require_rebuild_flush = {}
    autoscaler_flush = {}
#    autohealer_flush = {}

    if @property_flush[:ensure] == :absent
      delete_instance_group
      return
    end

    if @property_hash[:ensure] == :absent && @property_flush[:ensure] == :present
      fill_resource_instance_template resource, refetch: true
      create
      # continue as we want to set attributes like autoscaling policy/etc
      # copy necessary options to @property_flush
      # to let them adjust instance properties
      GCE_MNGD_GROUP_NO_RESTART_PROPERTY_NAMES.each {|v| @property_flush[v] = resource[v] }
      GCE_MNGD_GROUP_AUTOSCALER_PROPERTY_NAMES.each {|v| @property_flush[v] = resource[v] }
#      AUTOHEALER_PROPERTY_NAMES.each {|v| @property_flush[v] = resource[v] }
      [:name, :zone, :region].each {|v| @property_hash[v] = resource[v] }
    end

#    byebug

    # sort flushed properties in categories - no restart, needs restart, needs rebuild
    @property_flush.each {|key, value|
      if IGNORE_PROPERTY_NAMES.member? key
        next
      end
      if GCE_MNGD_GROUP_NO_RESTART_PROPERTY_NAMES.member? key
        no_restart_flush[key] = value
      elsif GCE_MNGD_GROUP_REBUILD_PROPERTY_NAMES.member? key
        require_rebuild_flush[key] = value
      elsif GCE_MNGD_GROUP_AUTOSCALER_PROPERTY_NAMES.member? key
        autoscaler_flush[key] = value
#      elsif AUTOHEALER_PROPERTY_NAMES.member? key
#        autohealer_flush[key] = value
      else
        require_rebuild_flush[key] = value
      end
    }

#    if @property_hash[:ensure] == :present and
#      require_restart_flush.length > 0 and
#      not [:rebuild, :restart].member? resource[:force_updates]
#      raise Puppet::Error, "Parameters requiring running instance restart need explicit permission, set force_updates => restart or rebuild."
#    end

    flush_properties no_restart_flush if no_restart_flush.length > 0
    flush_autoscaler_properties autoscaler_flush if autoscaler_flush.length > 0
  end# }}}

  def flush# {{{
	  set_instance_properties
  end# }}}

  def get_gce_area_prefix# {{{
    if @property_hash[:zone]
      zone = last_component @property_hash[:zone]
      "zones/#{zone}"
    else
      region = last_component @property_hash[:region]
      "regions/#{region}"
    end
  end# }}}

  # instance groups can be region or zone based, so special function to
  # generate prefix url
  def get_gce_prefix# {{{
	  group = last_component @property_hash[:name]
    "#{get_gce_area_prefix}/instanceGroupManagers/#{group}"
  end# }}}

  def flush_properties(properties)# {{{
	  if properties[:instance_template]
		  data = { 
        :instanceTemplate => get_gce_template_list( properties[:instance_template] )
      }
		  res = gce_api_POST "#{get_gce_prefix}/setInstanceTemplate", data, :beta
		  gce_WAIT res
	  end
    
	  if properties[:target_pools] && 
      !(@property_hash[:target_pools].nil? && properties[:target_pools].length == 0)
		  data = { 
			  :targetPools => properties[:target_pools].map {|v| get_gce_target_pool_list v}
		  }
		  res = gce_api_POST "#{get_gce_prefix}/setTargetPools", data, :beta
		  gce_WAIT res
	  end

    # BEFORE is DONE ---------------------
  end# }}}
  def flush_autoscaler_properties(properties)# {{{
    case resource[:autoscaling] 
    when :false
      # if previously used autoscaler, we need remove it
      if @property_hash[:autoscaling] == :cpu
        url = "#{get_gce_area_prefix}/autoscalers/#{resource[:name]}"
        res = gce_api_DELETE url, nil, :beta
        gce_WAIT res
      end

      if !properties[:size].nil?
        res = gce_api_POST "#{get_gce_prefix}/resize?size=#{properties[:size]}", nil, :beta
        gce_WAIT res
      end
    when :cpu
      request = {}

      if properties[:cool_down_period] 
        request[:coolDownPeriodSec] = properties[:cool_down_period] 
      end

      if properties[:min_num_replicas] 
        request[:minNumReplicas] = properties[:min_num_replicas] 
      end

      if properties[:max_num_replicas] 
        request[:maxNumReplicas] = properties[:max_num_replicas] 
      end

      if properties[:target_cpu_utilization] 
        request[:cpuUtilization] = {
          :utilizationTarget => properties[:target_cpu_utilization].to_f/100  
        }
      end

      data = {
        :autoscalingPolicy => request
      }

      if @property_hash[:autoscaling] == :cpu
        # updating settings
        url = "#{get_gce_area_prefix}/autoscalers?autoscaler=#{resource[:name]}"
        res = gce_api_PATCH url, data, :beta
      else
        # creating autoscaler
        data[:target] = (get_instance_group_managers_list resource[:name])['selfLink']
        [:name].each do |key|
          if !resource[key].nil?
            data[key] = resource[key]
          end
        end

        url = "#{get_gce_area_prefix}/autoscalers"
        res = gce_api_POST url, data, :beta
      end

      gce_WAIT res
    end


#	  if properties[:instance_template]
#		  data = { 
#        :instanceTemplate => get_gce_template_list( properties[:instance_template] )
#      }
#		  res = gce_api_POST "#{get_gce_prefix}/setInstanceTemplate", data
#		  gce_WAIT res
#	  end
#    
#	  if properties[:target_pools]
#      byebug
#
#		  data = { 
#			  :targetPools => properties[:target_pools].map {|v| get_gce_target_pool_list v}
#		  }
#		  res = gce_api_POST "#{get_gce_prefix}/setTargetPools", data
#		  gce_WAIT res
#	  end
#
#    # BEFORE is DONE ---------------------
  end# }}}

  def delete_instance_group # {{{
    # delete instance group manager
    res = gce_api_DELETE get_gce_prefix, nil, :beta
    gce_WAIT res

    # delete corresponding autoscaler
    url = "#{get_gce_area_prefix}/autoscalers/#{resource[:name]}"
    res = gce_api_DELETE url, nil, :beta
    gce_WAIT res, error_ok: true
  end# }}}

  def start_instance# {{{
	  group = last_component @property_hash[:name]
	  zone = last_component @property_hash[:zone]

	  res = gce_api_POST "zones/#{zone}/instances/#{group}/start"
	  gce_WAIT res, timeout: 120
  end# }}}

  def bring_online
    # mark for flush
	  @property_hash[:ensure] = self.ensure
	  @property_flush[:ensure] = :present
  end

end


# vim: sw=2 ts=2 et
