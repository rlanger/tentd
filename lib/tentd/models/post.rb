require 'securerandom'
require 'openssl'
require 'tent-canonical-json'

module TentD
  module Model

    class Post < Sequel::Model(TentD.database[:posts])
      plugin :serialization
      serialize_attributes :pg_array, :permissions_entities, :permissions_groups
      serialize_attributes :json, :mentions, :attachments, :version_parents, :licenses, :content

      def before_create
        self.public_id ||= TentD::Utils.random_id
        self.version = TentD::Utils.hex_digest(canonical_json)
      end

      def save_version
        data = as_json
        data[:version] = {
          :parents => [
            { :version => data[:version][:id] }
          ]
        }

        env = {
          'data' => TentD::Utils::Hash.stringify_keys(data),
          'current_user' => User.first(:id => user_id)
        }

        self.class.create_from_env(env)
      end

      def latest_version
        self.class.where(:public_id => public_id).order(Sequel.desc(:version_published_at)).first
      end

      def after_create
        return if version_parents && version_parents.any? # initial version only

        case TentType.new(type).base
        when 'https://tent.io/types/app'
          app = App.update_or_create_from_post(self)
        when 'https://tent.io/types/app-auth'
          credentials_post = Model::Credentials.generate(User.first(:id => user_id), self, :bidirectional_mention => true)
          # TODO: refactor into single query
          app_post = nil
          mentions.each do |m|
            _post = Post.first(:user_id => user_id, :public_id => m['post'])
            if _post.type == 'https://tent.io/types/app/v0#'
              app_post = _post
              break
            end
          end

          app = App.first(:post_id => app_post.id)
          app.update(:auth_code => credentials_post.content['hawk_key'])
        end
      end

      def self.create_from_env(env)
        data = env['data']
        current_user = env['current_user']
        type, base_type = Type.find_or_create(data['type'])

        received_at_timestamp = TentD::Utils.timestamp
        published_at_timestamp = (data['published_at'] || received_at_timestamp).to_i

        attrs = {
          :user_id => current_user.id,
          :entity_id => current_user.entity_id,
          :entity => current_user.entity,

          :type => type.type,
          :type_id => type.id,
          :type_base_id => base_type.id,

          :version_published_at => published_at_timestamp,
          :version_received_at => received_at_timestamp,
          :published_at => published_at_timestamp,
          :received_at => received_at_timestamp,

          :content => data['content'],
        }

        if data['version'] && Array === data['version']['parents']
          attrs[:version_parents] = data['version']['parents']
        end

        if data['permissions'] && !data['permissions']['public'].nil?
          attrs[:public] = data['permissions']['public']
        end

        if Array === data['mentions'] && data['mentions'].any?
          attrs[:mentions] = data['mentions']
        end

        if Array === env['attachments']
          attrs['attachments'] = env['attachments'].inject(Array.new) do |memo, attachment|
            memo << {
              :digest => TentD::Utils.hex_digest(attachment[:tempfile]),
              :size => attachment[:tempfile].size,
              :name => attachment[:name],
              :category => attachment[:category],
              :content_type => attachment[:content_type]
            }
            memo
          end
        end

        post = create(attrs)

        if Array === data['mentions']
          post.create_mentions(data['mentions'])
        end

        if Array === env['attachments']
          post.create_attachments(env['attachments'])
        end

        post
      end

      def create_attachments(attachments)
        attachments.each_with_index do |attachment, index|
          data = attachment[:tempfile].read
          attachment[:tempfile].rewind

          PostsAttachment.create(
            :attachment_id => Attachment.find_or_create(
              TentD::Utils::Hash.slice(self.attachments[index], 'digest', 'size').merge(:data => data)
            ).id,
            :post_id => self.id,
            :content_type => attachment[:content_type]
          )
        end
      end

      def create_mentions(mentions)
        mentions.map do |mention|
          mention_attrs = {
            :user_id => self.user_id,
            :post_id => self.id,
            :entity_id => Entity.first_or_create(mention['entity']).id
          }
          mention_attrs[:post] = mention['post'] if mention.has_key?('post')
          mention_attrs[:public] = mention['public'] if mention.has_key?('public')
          Mention.create(mention_attrs)
        end
      end

      def as_json(options = {})
        attrs = {
          :id => self.public_id,
          :type => self.type,
          :entity => self.entity,
          :published_at => self.published_at,
          :received_at => self.received_at,
          :content => self.content,
          :mentions => self.mentions,
          :version => {
            :id => self.version,
            :parents => self.version_parents,
            :message => self.version_message,
            :published_at => self.version_published_at,
            :received_at => self.version_received_at
          }
        }
        attrs[:version].delete(:parents) if attrs[:version][:parents].nil?
        attrs[:version].delete(:message) if attrs[:version][:message].nil?
        attrs[:version].delete(:received_at) if attrs[:version][:received_at].nil?
        attrs.delete(:received_at) if attrs[:received_at].nil?
        attrs.delete(:content) if attrs[:content].nil?
        attrs.delete(:mentions) if attrs[:mentions].nil?

        if Array(self.attachments).any?
          attrs[:attachments] = self.attachments
        end

        if self[:public] == false
          attrs[:permissions] = { :public => false }
        end

        attrs
      end

      private

      def canonical_json
        TentCanonicalJson.encode(as_json)
      end

    end

  end
end
