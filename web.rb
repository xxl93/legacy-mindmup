require 'pp'
require 'sinatra'
require 'uuid'
require 'aws-sdk'
require 'base64'

require File.dirname(__FILE__)+'/lib/s3_policy_signer.rb'
require File.dirname(__FILE__)+'/lib/browser_detection.rb'

require 'net/http'

def cache_last_news
  if ! test? then
    news = Net::HTTP.get(URI(ENV['NEWS_URL'] || 'http://blog.mindmup.com/feeds/posts/default?max-results=1' ))
    news =~ /<entry><id>([^<]*)<.*<title[^>]*>([^<]*)</
    set :last_news_id, $1
    set :last_news_title, $2
  end
end
configure do
  set :google_analytics_account, ENV["GOOGLE_ANALYTICS_ACCOUNT"]
  set :s3_website,ENV['S3_WEBSITE']
  set :base_url, ENV['SITE_URL'] || "/"
  set :s3_key_id, ENV['S3_KEY_ID']
  set :s3_form_expiry, (60*60*24*30)
  set :s3_bucket_name, ENV['S3_BUCKET_NAME']
  set :s3_secret_key, ENV['S3_SECRET_KEY']
  set :s3_upload_folder, ENV['S3_UPLOAD_FOLDER']
  set :default_map, ENV['DEFAULT_MAP']|| "map/default"
  set :s3_max_upload_size, ENV['MAX_UPLOAD_SIZE']||100
  set :max_upload_size, ENV['MAX_UPLOAD_SIZE']||100
  set :key_id_generator, UUID.new
  set :current_map_data_version, ENV['CURRENT_MAP_DATA_VERSION'] || "a1"
  set :network_timeout_millis, ENV['NETWORK_TIMEOUT_MILLIS']||10000
  set :publishing_config_url, '/publishingConfig'
  set :proxy_load_url, 's3proxy/'
  set :async_scripts, '//www.google-analytics.com/ga.js //platform.twitter.com/widgets.js //connect.facebook.net/en_US/all.js#xfbml=1'
  offline =  ENV['OFFLINE'] || "online"
  set :online, offline == "offline" ? false : true
  AWS.config(:access_key_id=>settings.s3_key_id, :secret_access_key=>settings.s3_secret_key)
  s3=AWS::S3.new()
  set :s3_bucket, s3.buckets[settings.s3_bucket_name]
  set :root, File.dirname(__FILE__)
  set :cache_prevention_key, settings.key_id_generator.generate(:compact)
  set :static, true
  Rack::Mime::MIME_TYPES['.mup'] = 'application/json'
  Rack::Mime::MIME_TYPES['.mm'] = 'text/xml'
  cache_last_news
end
get '/' do
  show_map
end

get '/gd' do

  begin
    state = JSON.parse(params[:state])
    if state['action']=='create' then
      mapid = "new-g"
    else
      mapid = "g1" + state['ids'][0]
    end
    redirect "/#m:"+mapid
  rescue Exception=>e
    puts e
    halt 400, "Google drive state missing or invalid"
  end
end
get '/fb' do
	redirect "http://facebook.com/mindmupapp"
end
get '/github/login' do
  github_login_response
end
get '/github/postback' do
  content_type 'application/json'
  json_fail "invalid response from github" unless params[:code]
  if (params[:state]!= settings.cache_prevention_key) then
    pp settings.cache_prevention_key
    return github_login_response
  end
  begin
    uri = URI('https://github.com/login/oauth/access_token')
    https = Net::HTTP.start(uri.host, uri.port, :use_ssl=>uri.scheme =='https')
    response=https.post(uri.path, "client_id=#{ENV["GITHUB_CLIENT_ID"]}&client_secret=#{ENV["GITHUB_SECRET"]}&code=#{params[:code]}")
    json_fail response.body unless response.code == "200"
    tokens = Rack::Utils.parse_query response.body
    json_fail tokens["error"] if tokens["error"]
    json_fail "Unknown github response" unless tokens["access_token"]
    %Q{{"access_token" : "#{tokens["access_token"]}"}}
  rescue Exception=>e
    json_fail "Network error"
  end
end
get '/trouble' do
 erb :trouble
end
get '/default' do
  redirect "/#m:default"
end
get "/s3/:mapid" do
  redirect "/#m:#{params[:mapid]}"
end

get "/s3proxy/:mapid" do
  content_type 'application/json'
  settings.s3_bucket.objects[map_key(params[:mapid])].read
end

post "/echo" do
  attachment params[:title]
  contents = params[:map]
  if (contents.start_with?('data:')) then
    data = contents.split(',')
    meta = data[0].split(':')[1].split(';')
    content_type meta[0]
    if (meta[1] != 'base64') then
      halt 503, "Unsupported encoding " + meta [1]
    end
    Base64.decode64 data[1]
  else
    content_type 'application/octet-stream'
    contents
  end
end

get "/map/:mapid" do
  redirect "/#m:#{params[:mapid]}"
end
get "/m" do
  show_map
end
get "/publishingConfig" do
  @s3_upload_identifier = settings.current_map_data_version +  settings.key_id_generator.generate(:compact)
  @s3_key=settings.s3_upload_folder+"/" + @s3_upload_identifier + ".json"
  @s3_content_type="text/plain"
  signer=S3PolicySigner.new
  @policy=signer.signed_policy settings.s3_secret_key, settings.s3_key_id, settings.s3_bucket_name, @s3_key, settings.s3_max_upload_size*1024, @s3_content_type, settings.s3_form_expiry
  erb :s3UploadConfig
end

get '/browserok/:mapid' do
  session['browserok']=true
  redirect "/#m:#{params[:mapid]}"
end
post '/import' do
  file = params['file']
  json_fail('No file uploaded') unless file 
  uploaded_size=request.env['CONTENT_LENGTH']
  json_fail('Browser did not provide content length for upload') unless uploaded_size
  json_fail("File too big. Maximum size is #{settings.max_upload_size}kb") if uploaded_size.to_i>settings.max_upload_size*1024
  allowed_types=[".mm", ".mup"]
  uploaded_type= File.extname file[:filename]
  json_fail "unsupported file type #{uploaded_type}" unless allowed_types.include? uploaded_type
  result=File.readlines(file[:tempfile]).join  ' '
  content_type 'text/plain'
  result
end
get "/un" do
  erb :unsupported
end

get '/'+settings.cache_prevention_key+'/e/:fname' do
  send_file File.join(settings.public_folder, 'e/'+params[:fname])
end

get '/cache_news' do
  cache_last_news
  "OK "+settings.last_news_id
end

include Sinatra::UserAgentHelpers
helpers do
  def show_map
    if (browser_supported? || user_accepted_browser?)
      erb :editor
    else
      erb :unsupported
    end
  end
  def user_accepted_browser?
    !(session["browserok"].nil?)
  end
  def browser_supported? 
    browser.chrome? || browser.gecko? || browser.safari?
  end
  def json_fail message
    halt %Q!{"error":"#{message}"}!
  end
  def map_key mapid
    (mapid.include?("/") ?  "" : settings.s3_upload_folder + "/") + mapid + ".json"
  end
  def user_cohort
     session["cohort"]= Time.now.strftime("%Y%m%d") if session["cohort"].nil?
     session["cohort"]
  end
  def join_scripts script_url_array
    return script_url_array if (development? || test?)
    target_file="#{settings.public_folder}/#{settings.cache_prevention_key}.js" 

    if (!File.exists? target_file) then
      script_url_array.each do |input_file|
        infile = "#{settings.public_folder}/#{input_file}"
        if !File.exists? infile then
          halt 503, "Script file not found! #{input_file}"
        end
      end
      File.open(target_file,"w") do |output_file|
        script_url_array.each do |input_file|
          infile = "#{settings.public_folder}/#{input_file}"
          content= File.readlines(infile)
          output_file.puts content
        end
      end
    end
    return ["/#{settings.cache_prevention_key}.js"] 
  end
  def load_prefix
    if (!settings.online) then
      "offline"
    else
      ""
    end
  end
  def load_scripts script_url_array
    script_tags=script_url_array.map do |url|
      if (!settings.online) then
        url.sub!("//","/offline/")
      end
      %Q{<script>ScriptHelper.currentScript='#{url}'; ScriptHelper.expectedScripts.push('#{url}');</script>
        <script src='#{url}' onload='ScriptHelper.loadedScripts.push("#{url}")' onerror='ScriptHelper.errorScripts.push("#{url}")'></script>}
    end
   %Q^<script>
      var ScriptHelper={
        loadedScripts:[],
        expectedScripts:[],
        errorScripts:[],
        jsErrors:[],
        logError:function(message,url,line){
          ScriptHelper.jsErrors.push({'message':message, 'url':url||ScriptHelper.currentScript, 'line':line});
        },
        failed: function(){
          return ScriptHelper.errorScripts.length>0 || ScriptHelper.jsErrors.length>0 || ScriptHelper.loadedScripts.length!=#{script_url_array.length}
        },
        failedScripts: function(){
          var keys={},idx,result=[];
          for (idx in ScriptHelper.errorScripts) { keys[ScriptHelper.errorScripts[idx]]=true };
          for (idx in ScriptHelper.jsErrors) { keys[ScriptHelper.jsErrors[idx].url]=true };
          for (idx in ScriptHelper.expectedScripts) { if (ScriptHelper.loadedScripts.indexOf(ScriptHelper.expectedScripts[idx])<0) keys[ScriptHelper.expectedScripts[idx]]=true; }
          for (idx in keys) {result.push(idx)};
          return result;
        },
		loading: function(){
			return ScriptHelper.errorScripts.length==0 && ScriptHelper.jsErrors.length==0 && ScriptHelper.loadedScripts.length<ScriptHelper.expectedScripts.length;
		},
		afterLoad: function(config){
			ScriptHelper.loadWaitRetry=(ScriptHelper.loadWaitRetry||50)-1;
			if (ScriptHelper.loading() && ScriptHelper.loadWaitRetry>0){
				setTimeout( function(){ScriptHelper.afterLoad(config)},100);
			}
			else {
				if (ScriptHelper.failed()) config.fail(); else config.success();
			}
		}	
      };
      window.onerror=ScriptHelper.logError;
    </script>
    #{script_tags.join('')}
    <script>
      window.onerror=function(){};
    </script>
     ^
  end
  def github_login_response
    content_type 'application/json'
    %Q{{"login-at": "https://github.com/login/oauth/authorize?client_id=#{ENV["GITHUB_CLIENT_ID"]}&scope=repo&state=#{settings.cache_prevention_key}"}}
  end
end

