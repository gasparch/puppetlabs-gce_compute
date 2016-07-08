require 'puppet_x/puppetlabs/name_validator'

Puppet::Type.newtype(:gce_disk) do
  desc 'Google Compute Engine persistent disk.'

  ensurable 
  #do
#	  newvalue(:present) do
#		  byebug
#		  if provider.ensure == :absent then
#			  provider.create
#		  else
#			  provider.start
#		  end
#	  end
#	  newvalue(:absent) do
#		  byebug
#		  provider.destroy
#	  end
#  end

  newparam(:name, :namevar => true) do
    desc 'The name of the disk.'
    validate do |v|
	  host_part = v.sub(%r{^.*/}, '')
      PuppetX::Puppetlabs::NameValidator.validate(host_part)
    end
  end

  newproperty(:zone) do
    desc 'The zone of the disk.'
  end

  newparam(:description) do
    desc 'An optional, textual description for the disk.'
  end

  newparam(:force_updates) do
	  desc 'Permit instance restart or deletion if other parameter changes require it.'

	  newvalues(:delete_instance, :resize, :false)
	  defaultto :false
  end

  newproperty(:size) do
    desc 'Indicates the size (in GB) of the disk.'
  end

  newproperty(:image) do
    desc 'An image to apply to the disk.'
  end

  newparam(:image_regexp) do
    desc 'An image to apply to the disk.'
  end

  newproperty(:users) do
    desc 'Which instances are using the disk.'
  end

  validate do
	if self[:name].match(%r{/})
		self[:zone],self[:name] = self[:name].split('/')
	end
    fail('You must specify a zone for the disk.') unless self[:zone]
  end
end
