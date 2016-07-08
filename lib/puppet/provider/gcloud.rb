require 'set'
require 'net/http'
require 'uri'
require 'json'

require 'pry'

class Puppet::Provider::Gcloud < Puppet::Provider
  THREAD_COUNT = 8  # tweak this number for maximum performance.

  # These arguments are required for both create and destroy
  def gcloud_args
    {}
  end

  def gcloud_optional_create_args
    {}
  end

  def exists?
    begin
      gcloud(*build_gcloud_args('describe'))
      return true
    rescue Puppet::ExecutionFailure => e
      return false
    end
  end

  def create
    gcloud(*(build_gcloud_args('create') + build_gcloud_flags(gcloud_optional_create_args)))
  end

  def destroy
    gcloud(*build_gcloud_args('delete'))
  end

  def build_gcloud_args(action)
	  if resource.nil?
		['compute', gcloud_resource_name, action]
	  else
		['compute', gcloud_resource_name, action, resource[:name]] + build_gcloud_flags(gcloud_args)
	  end
  end

  def build_gcloud_flags(args_hash)
    args = []
    args_hash.each do |attribute, flag|
      if resource[attribute]
        args << flag
        if resource[attribute].is_a? Array
          args << resource[attribute].join(',')
        else
          args << resource[attribute]
        end
      end
    end
    return args
  end

  def self.get_gce_token# {{{
	if not defined? @gce_token
		@gce_token = gcloud(['auth', 'print-access-token']).strip!
	end
	@gce_token
  end# }}}

  def self.get_gce_project# {{{
	if not defined? @gce_project
		@gce_project = gcloud(['config', 'list', 'core/project']).
			split("\n").
			grep(/project =/)[0].
			split(/\s*=\s*/)[1]
	end
	@gce_project
  end# }}}

  def parallel_get_urls (urls)# {{{
	  responses = []
	  mutex = Mutex.new

	  THREAD_COUNT.times.map {
		  Thread.new(urls, responses) do |urls, responses|
			  while url = mutex.synchronize { urls.pop }
				  response = gce_api_GET(url)
				  mutex.synchronize { responses << response }
			  end
		  end
	  }.each(&:join)

	  responses
  end# }}}

  def gce_api_calculate_url (api_url, version=:v1)# {{{
	project = self.class.get_gce_project

	case version
	when :v1
		gce_base = "https://www.googleapis.com/compute/v1/projects"
	when :beta
		gce_base = "https://www.googleapis.com/compute/beta/projects"
	end

	if api_url != ""
		"#{gce_base}/#{project}/#{api_url}"
	else
		"#{gce_base}/#{project}"
	end
  end# }}}

  def gce_api_GET (api_url, version=:v1) # {{{
	token = self.class.get_gce_token
	uri = URI.parse(gce_api_calculate_url(api_url, version))

	Puppet.debug "gce_api_GET: #{api_url}"

	request = Net::HTTP::Get.new(uri.request_uri)
	request['Authorization'] = "Bearer #{token}"

	response =  Net::HTTP.start(uri.hostname, uri.port,
								:use_ssl => uri.scheme == 'https') { |http|
		http.request request
	}

	JSON.parse(response.body)
  end# }}}

  def gce_api_POST (api_url, arguments=nil, version=:v1) # {{{
	token = self.class.get_gce_token
	uri = URI.parse(gce_api_calculate_url(api_url, version))

	Puppet.debug "gce_api_POST: #{api_url}"

	request = Net::HTTP::Post.new(uri.request_uri)
	request['Authorization'] = "Bearer #{token}"
	request.content_type = 'application/json'
	if not arguments.nil?
		request.body = JSON.generate(arguments)
		Puppet.debug "gce_api_POST: #{arguments.inspect}"
	end

	response =  Net::HTTP.start(uri.hostname, uri.port,
								:use_ssl => uri.scheme == 'https') { |http|
		http.request request
	}

	JSON.parse(response.body)
  end# }}}

  def gce_api_PATCH (api_url, arguments=nil, version=:v1) # {{{
	token = self.class.get_gce_token
	uri = URI.parse(gce_api_calculate_url(api_url, version))

	Puppet.debug "gce_api_PATCH: #{api_url}"

	request = Net::HTTP::Patch.new(uri.request_uri)
	request['Authorization'] = "Bearer #{token}"
	request.content_type = 'application/json'
	if not arguments.nil?
		request.body = JSON.generate(arguments)
		Puppet.debug "gce_api_PATCH: #{arguments.inspect}"
	end

	response =  Net::HTTP.start(uri.hostname, uri.port,
								:use_ssl => uri.scheme == 'https') { |http|
		http.request request
	}

	JSON.parse(response.body)
  end# }}}

  def gce_api_DELETE (api_url, arguments=nil, version=:v1) # {{{
	token = self.class.get_gce_token
	uri = URI.parse(gce_api_calculate_url(api_url, version))

	Puppet.debug "gce_api_DELETE: #{api_url}"

	request = Net::HTTP::Delete.new(uri.request_uri)
	request['Authorization'] = "Bearer #{token}"
	request.content_type = 'application/json'

	if !arguments.nil?
		request.body = JSON.generate(arguments)
		Puppet.debug "gce_api_DELETE: #{arguments.inspect}"
	end

	response =  Net::HTTP.start(uri.hostname, uri.port,
								:use_ssl => uri.scheme == 'https') { |http|
		http.request request
	}

	JSON.parse(response.body)
  end# }}}

  def gce_api_WAIT(operation_id, area_id: , area_type: :zone, timeout: 30, call_by:)# {{{
	case area_type
	when :zone
		api_url = "zones/#{area_id}/operations/#{operation_id}"
	when :region
		api_url = "regions/#{area_id}/operations/#{operation_id}"
	when :global
		api_url = "global/operations/#{operation_id}"
	else
		raise Puppet::Error, "Area type #{areaType} not supported yet."
	end

	i = 0
	begin
		response = gce_api_GET api_url
		if response['status'] == 'DONE'
			return true
		end
		sleep 1
		i += 1
		Puppet.debug "#{call_by} wait: operation in progress, try #{i}"
	end while i < timeout

	false
  end# }}}

  def gce_WAIT(response, timeout: 30, error_ok: false, call_by: 'gce_instance') # {{{
	  if response['error']
		  return true if error_ok

		  raise Puppet::Error, "GCE returned error #{response['error']['errors'][0]['message']}"
		  return false
	  end
	  if response['zone']
		  area_type = :zone
		  area_id = last_component response['zone']
	  end
	  if response['region']
		  area_type = :region
		  area_id = last_component response['region']
	  end
	  if !area_type
		  area_type = :global
		  area_id = nil
	  end

	  gce_api_WAIT(response['name'], area_id: area_id, area_type: area_type, 
				   timeout: timeout, call_by: call_by)
  end# }}}

  def get_gce_private_image_list
	  if not @gce_images
		  response = gce_api_GET "global/images", :beta
		  @gce_images = response['items'].map {|v| v['name']}.sort
	  end
	  @gce_images
  end

  # returned list should be SORTED!
  # caller relies on that to get latest element with .last
  def get_gce_template_list(name=nil, refetch=false)
	  if not @gce_templates || refetch
		  response = gce_api_GET "global/instanceTemplates"
		  @gce_templates = response['items'].map {|v| v['name']}.sort
		  @gce_templates_hash = {}
		  response['items'].each do |v|
			  @gce_templates_hash[v['name']] = v['selfLink']
		  end
	  end
	  if name.nil?
		  @gce_templates
	  else
		  @gce_templates_hash[name]
	  end
  end

  def get_gce_target_pool_list(name=nil)
	  if not @gce_target_pools
		  response = (gce_api_GET "aggregated/targetPools", :beta)['items'].
			  select {|k, v| v['targetPools']}.
			  map {|k, v| v['targetPools']}.
			  flatten

		  @gce_target_pools = response.map {|v| v['name']}.sort
		  @gce_target_pools_hash = {}
		  response.each do |v|
			  @gce_target_pools_hash[v['name']] = v['selfLink']
		  end
	  end

	  if name.nil?
		  @gce_target_pools
	  else
		  @gce_target_pools_hash[name]
	  end
  end

  def self.last_component x# {{{
	  if x.nil?
		  byebug
	  end

	  x.split('/').last
  end# }}}

  def last_component x
	  self.class.last_component x
  end

end
