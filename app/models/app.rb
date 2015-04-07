class App < ActiveRecord::Base

  NULL_IF_BLANK_ATTRS = %w( icon description short_description privacy_url accessibility_url vpat_url acceptable lti_configuration_url lti_registration_url lti_outcomes ios_app_id ios_app_scheme ios_app_path ios_app_affiliate_data android_app_package android_app_scheme android_app_action android_app_category android_app_component lti_launch_url )

  include ActionView::Helpers::SanitizeHelper
  include ActionView::Helpers::TextHelper

  has_and_belongs_to_many :categories
  has_many :app_tags
  has_many :app_authors, :dependent => :destroy
  has_many :app_organizations, :dependent => :destroy
  belongs_to :app_privacy_policy
  has_many :app_media_requirements
  has_many :app_lti_versions
  has_many :app_browser_features
  has_many :app_out_peer_permissions
  has_many :app_launch_methods

  scope :available_to_launch_method, lambda { |m|
    if m
      joins('LEFT OUTER JOIN `app_launch_methods` ON `apps`.`id` = `app_launch_methods`.`app_id`').where('restrict_launch = 0 OR `app_launch_methods`.`method` = :method', { method: m })
    end
  }

  validates :title,
    presence: true,
    length: { minimum: 1 }

  before_save do
    ['icon'].each { |column| self[column].present? || self[column] = nil }
    NULL_IF_BLANK_ATTRS.each { |attr| self[attr] = nil if self[attr].blank? }
  end

  after_save do
    remove_from_index!
    add_to_index! if self.enabled
  end

  before_destroy do
    remove_from_index!
  end

  def icon_tag
    if self.icon
      raw "<img src='#{self.icon.gsub /'/, '\\\''}' alt='#{self.title.gsub /'/, '\\\''}'>"
    else
      #$('<span>').html(app.title.charAt(0)).appendTo($imgContainer);
      raw "<div class='letter-icon'><span>#{self.title[0,1]}</span></div>"
    end
  end

  def formatted_description
    unless description.index('<').nil?
      sanitize description, tags: %w(h1 h2 h3 h4 h5 h6 p ul ol li strong em b i u), attributes: []
    else
      simple_format description
    end
  end

  def originated?
    self.casa_in_payload.nil?
  end

  def payload_id
    (self.casa_id ? self.casa_id : self.id).to_s
  end

  def payload_originator_id
    (self.casa_originator_id ? self.casa_originator_id : Rails.application.config.casa[:engine][:uuid]).to_s
  end

  def to_transit_payload

    if originated?

      payload = {
          'identity' => {
              'id' => payload_id,
              'originator_id' => payload_originator_id
          },
          'original' => {
              'uri' => self.uri,
              'share' => self.share,
              'propagate' => self.propagate,
              'timestamp' => self.updated_at.to_datetime.rfc3339,
              'use' => {},
              'require' => {}
          }
      }

      Casa::Payload.attributes_map.each do |type, mappings|
        mappings.each do |field, klass|
          key = klass.send :uuid
          if klass.respond_to?(:make_for) # use handler's mapping function to compute payload value from app value
            value = klass.make_for(self)
          else # directly copy value from app to payload
            value = self.send(field)
          end
          payload['original'][type][key] = value unless value.nil?
        end
      end

      payload

    else

      JSON.parse self.casa_in_payload

    end

  end

  def to_local_payload

    payload = {
        'identity' => {
            'id' => payload_id,
            'originator_id' => payload_originator_id
        },
        'attributes' => {
            'uri' => self.uri,
            'share' => self.share,
            'propagate' => self.propagate,
            'timestamp' => self.updated_at.to_datetime.rfc3339,
            'use' => {},
            'require' => {}
        }
    }

    Casa::Payload.attributes_map.each do |type, mappings|
      mappings.each do |field, klass|
        key = klass.send :name
        value = klass.respond_to?(:make_for) ? klass.make_for(self) : self.send(field)
        payload['attributes'][type][key] = value unless value.nil?
      end
    end

    payload

  end

  def to_content_item

    content_item = {
      'title' => self.title.length > 0 ? self.title : 'Untitled',
      'url' => self.uri
    }

    if self.lti
      content_item['mediaType'] = 'application/vnd.ims.lti.v1.ltilink'
      content_item['url'] = self.lti_launch_url if self.lti_launch_url
    else
      content_item['mediaType'] = 'text/html'
    end

    content_item['text'] = self.description if self.description.length > 0

    # TODO: add icon and thumbnail properties

    content_item

  end

  def add_to_index!

    return if elasticsearch_client.nil?

    elasticsearch_client.create index: Rails.application.config.elasticsearch_index,
                                type: 'local',
                                id: self.id,
                                body: to_local_payload

  end

  def remove_from_index!

    return if elasticsearch_client.nil?

    begin
      elasticsearch_client.delete index: Rails.application.config.elasticsearch_index,
                                  type: 'local',
                                  id: self.id
    rescue Elasticsearch::Transport::Transport::Errors::NotFound
      # fail silently -- this is okay!
    rescue => e
      puts e.class.name
      puts e
    end

  end

  private

  def elasticsearch_client
    Rails.application.config.elasticsearch_client
  end

  class << self

    def where_identity identity

      return nil unless identity.include?(:id) and identity.include?(:originator_id)

      if identity[:originator_id] == Rails.application.config.casa[:engine][:uuid]
        App.where(casa_in_payload: nil,
                  share: true,
                  id: identity[:id]).first
      else
        App.where("casa_in_payload IS NOT NULL").where(share: true,
                                                       casa_id: identity[:id],
                                                       casa_originator_id: identity[:originator_id]).first
      end

    end

    def where_query_string qs

      return nil if elasticsearch_client.nil?

      res = elasticsearch_client.search index: Rails.application.config.elasticsearch_index,
                                        type: 'local',
                                        q: qs

      App.where id: res['hits']['hits'].map(){ |app| app['_id'] }

    end

    def where_query qb

      return nil if elasticsearch_client.nil?

      res = elasticsearch_client.search index: Rails.application.config.elasticsearch_index,
                                        type: 'local',
                                        body: qb

      App.where id: res['hits']['hits'].map(){ |app| app['_id'] }

    end

    def init_index!

      return if elasticsearch_client.nil?

      unless elasticsearch_client.indices.exists index: Rails.application.config.elasticsearch_index
        elasticsearch_client.indices.create index: Rails.application.config.elasticsearch_index, body: {}
      end

    end

    def drop_index!

      return if elasticsearch_client.nil?

      if elasticsearch_client.indices.exists index: Rails.application.config.elasticsearch_index
        elasticsearch_client.indices.delete index: Rails.application.config.elasticsearch_index
      end

    end

    private

    def elasticsearch_client
      Rails.application.config.elasticsearch_client
    end

  end

end
