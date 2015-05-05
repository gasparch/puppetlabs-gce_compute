require 'spec_helper'
require 'helpers/integration_spec_helper'

describe "gce_instance" do
  it_behaves_like "a resource that can be created and destroyed" do
    let(:type) { Puppet::Type.type(:gce_instance) }
    let(:describe_args) { 'puppet-test-instance --zone us-central1-a' }
    let(:expected_properties) { {'name'        => 'puppet-test-instance',
                                 'zone'        => /us-central1-a/,
                                 'description' => "Instance for testing the puppetlabs-gce_compute module",
                                 'machineType' => /f1-micro/,
                                 'machineType' => /f1-micro/,
                                 'canIpForward' => true} }
    let(:other_property_expectations) do
      Proc.new do |out|
        expect(out['networkInterfaces'].size).to eq(1)
        expect(out['networkInterfaces'][0]['network']).to match(/puppet-test-instance-network/)
        expect(out['scheduling']['onHostMaintenance']).to match('TERMINATE')
      end
    end
  end
end
