require 'puppet_x/puppetlabs/name_validator'
require 'puppet/parameter/boolean'


Puppet::Type.newtype(:gce_projectmetadata) do
  desc 'Google Compute Engine project metadata manager.'

#  ensurable 

  newparam(:name, :namevar => true) do
	  desc 'Descriptive name, ignored when setting variables.'
  end

  newproperty(:metadata) do
    desc 'Metadata to be made available to the guest operating system running on the instances.'
  end

  newparam(:convert_hash_to_json, :boolean => true, :parent => Puppet::Parameter::Boolean) do
    desc 'If variables contain hash in them, convert it to JSON'
	defaultto false
  end

  newparam(:allow_sshkeys_override, :boolean => true, :parent => Puppet::Parameter::Boolean) do
    desc 'Allow write to sshKeys in metadata, which may lock you out of project.'
	defaultto false
  end

#  validate do
#	if self[:name].match(%r{/})
#		self[:zone],self[:name] = self[:name].split('/')
#	end
#    fail('You must specify a zone for the disk.') unless self[:zone]
#  end
end
