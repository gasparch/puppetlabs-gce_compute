require 'spec_helper'
require 'helpers/integration_spec_helper'

describe "gce_httpshealthcheck" do
  it_behaves_like "a resource that can be created and destroyed" do
    let(:type_name) { 'gce_httpshealthcheck' }
    let(:gcloud_resource_name) { 'https-health-checks' }
    let(:describe_args) { 'puppet-test-https-health-check' }
    let(:expected_properties) { {'name'               => 'puppet-test-https-health-check',
                                 'checkIntervalSec'   => 7,
                                 'timeoutSec'         => 7,
                                 'description'        => "Https-health-check for testing the puppetlabs-gce_compute module",
                                 'healthyThreshold'   => 7,
                                 'host'               => 'testhost',
                                 'port'               => 666,
                                 'requestPath'        => '/test/path',
                                 'unhealthyThreshold' => 7} }
  end
end
