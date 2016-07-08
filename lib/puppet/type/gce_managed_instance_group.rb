require 'puppet_x/puppetlabs/name_validator'

Puppet::Type.newtype(:gce_managed_instance_group) do
  desc 'Google Compute Engine instance template manager'

  ensurable do
    newvalue(:present) do
      provider.bring_online
    end

    newvalue(:absent) do
      provider.destroy
    end
  end

  newparam(:name, :namevar => true) do
    desc 'The name of the instance'
    validate do |v|
      host_part = v.sub(%r{^.*/}, '') # /
      PuppetX::Puppetlabs::NameValidator.validate(host_part)
    end
  end

  newparam(:instance_template_regexp) do
    desc 'The pattern to look up for new templates'
  end

  newproperty(:zone) do
    desc 'The zone of the instance group.'
    validate do |v|
      PuppetX::Puppetlabs::NameValidator.validate(v)
    end
  end

  newproperty(:region) do
    desc 'The region of the instance group.'
    validate do |v|
      PuppetX::Puppetlabs::NameValidator.validate(v)
    end
  end

  newproperty(:instance_template) do
    desc 'Current instance template used for managed group.'
  end

  newproperty(:base_instance_name) do
    desc 'Name prefix for new instances.'
  end

  newproperty(:template_name) do
    desc 'The current full template name.'
  end

  newproperty(:target_pools, :array_matching => :all) do
    desc 'Specifies any target pools you want the instances of this managed instance group to be part of.'
#    defaultto []
    def insync?(is)
      if is.is_a?(Array) and @should.is_a?(Array)
        is.sort == @should.sort
      else
        is == @should
      end
    end
  end

  newproperty(:cool_down_period) do
    desc 'Number of seconds Autoscaler will wait between resizing collection.'
  end

  newproperty(:size) do
    desc 'Size of managed instance group.'
    defaultto 0
  end

  newproperty(:min_num_replicas) do
    desc 'Minimum number of replicas Autoscaler will set.'
  end

  newproperty(:max_num_replicas) do
    desc 'Maximum number of replicas Autoscaler will set.'
  end

  newproperty(:autoscaling) do
    desc 'Tell which kind of autoscaling to use.'
    newvalues(:cpu, :false) # add :load_balancing later
    defaultto :false
  end

  newproperty(:target_cpu_utilization) do
    desc 'CPU utilization level Autoscaler will aim to maintain (0-100)'
  end

#  TBD
#  newproperty(:http_health_check) do
#    desc 'Number of seconds Autoscaler will wait between resizing collection.'
#  end
#
#  newproperty(:https_health_check) do
#    desc 'Number of seconds Autoscaler will wait between resizing collection.'
#  end
#
#  newproperty(:health_check_initial_delay) do
#    desc 'Number of seconds Autoscaler will wait between resizing collection.'
#  end

  validate do

    if self[:autoscaling] != :cpu
      if self[:min_num_replicas]
        fail("cannot use min_num_replicas if autoscaling is not cpu")
      end
      if self[:max_num_replicas]
        fail("cannot use max_num_replicas if autoscaling is not cpu")
      end
      if self[:target_cpu_utilization]
        fail("cannot use target_cpu_utilization if autoscaling is not cpu")
      end
    end

    if self[:autoscaling] != :false
      if self[:size] > 0
        fail("cannot use size if autoscaling is not false")
      end
    end

    if self[:autoscaling] == :cpu
      if !self[:min_num_replicas] || !self[:max_num_replicas] || !self[:target_cpu_utilization]
        fail("not all parameres (min_num_replicas, max_num_replicas, target_cpu_utilization) specified")
      end
    end

    #	if self[:name].match(%r{/})
    #		self[:zone],self[:name] = self[:name].split('/')
    #	end
    #
    #    fail('You must specify a zone for the instance.') unless self[:zone]
    #    if self[:block_for_startup_script]
    #      fail('You must specify a startup script if :block_for_startup_script is set to true.') unless self[:startup_script]
    #    end
    #    if self[:startup_script_timeout]
    #      fail(':block_for_startup_script must be set to true if you specify :startup_script_timeout.') unless self[:block_for_startup_script]
    #    end
  end
end

# vim: sw=2 ts=2 expandtab
