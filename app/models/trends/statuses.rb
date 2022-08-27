# frozen_string_literal: true

class Trends::Statuses < Trends::Base
  PREFIX = 'trending_statuses'

  self.default_options = {
    threshold: 5,
    review_threshold: 3,
    score_halflife: 2.hours.freeze,
    decay_threshold: 0.3,
  }

  class Query < Trends::Query
    def filtered_for!(account)
      @account = account
      self
    end

    def filtered_for(account)
      clone.filtered_for!(account)
    end

    def to_arel
      scope = Status.joins(:trend).reorder(score: :desc)
      scope = scope.reorder(language_order_clause.desc, score: :desc) if @locale.present?
      scope = scope.merge(Trends::Status.allowed) if @allowed
      scope = scope.not_excluded_by_account(@account).not_domain_blocked_by_account(@account) if @account.present?
      scope = scope.offset(@offset) if @offset.present?
      scope = scope.limit(@limit) if @limit.present?
      scope
    end

    private

    def language_order_clause
      Arel::Nodes::Case.new
                       .when(Trends::Status.arel_table[:language].eq(@locale)).then(2)
                       .when(Trends::Status.arel_table[:language].eq(I18n.default_locale)).then(1)
                       .else(0)
    end
  end

  def register(status, at_time = Time.now.utc)
    add(status.proper, status.account_id, at_time) if eligible?(status.proper)
  end

  def add(status, _account_id, at_time = Time.now.utc)
    record_used_id(status.id, at_time)
  end

  def query
    Query.new(key_prefix, klass)
  end

  def refresh(at_time = Time.now.utc)
    statuses = Status.where(id: (recently_used_ids(at_time) + Trends::Status.pluck(:id)).uniq).includes(:status_stat)
    calculate_scores(statuses, at_time)
  end

  def request_review
    score_at_threshold = score_at_rank(options[:review_threshold])
    trending_statuses  = Trends::Status.joins(:status).includes(status: :account)

    trending_statuses.filter_map do |trending_status|
      status = trending_status.status

      if trending_status.score > score_at_threshold && !status.trendable? && status.requires_review_notification?
        status.account.touch(:requested_review_at)
        status
      end
    end
  end

  def at_review_threshold
    query.allowed.limit(options[:review_threshold]).last
  end

  def score(id, **)
    Trends::Status.find_by(id: id)&.score
  end

  def rank(id, **)
    scope = Trends::Status.allowed.select(Trends::Status.arel_table[Arel.star], 'ROW_NUMBER() OVER(ORDER BY score DESC) AS rank')
    Trends::Status.select('s.rank').from(scope.arel.as('s')).find_by('s.id = ?', id)&.rank
  end

  def currently_trending_ids(allowed, limit)
    Trends::Status.where(allowed: allowed).limit(limit).pluck(:id)
  end

  protected

  def key_prefix
    PREFIX
  end

  def klass
    Status
  end

  private

  def eligible?(status)
    status.public_visibility? && status.account.discoverable? && !status.account.silenced? && status.spoiler_text.blank? && !status.sensitive? && !status.reply?
  end

  def calculate_scores(statuses, at_time)
    items = statuses.map do |status|
      expected  = 1.0
      observed  = (status.reblogs_count + status.favourites_count).to_f

      score = begin
        if expected > observed || observed < options[:threshold]
          0
        else
          ((observed - expected)**2) / expected
        end
      end

      decaying_score = score * (0.5**((at_time.to_f - status.created_at.to_f) / options[:score_halflife].to_f))

      [decaying_score, status]
    end

    Trends::Status.transaction do
      Trends::Status.upsert_all(items.map { |(score, status)| { id: status.id, account_id: status.account_id, score: score, language: status.language, allowed: status.trendable? } }, unique_by: :id)
      Trends::Status.where('score < ?', options[:decay_threshold]).delete_all
    end
  end

  def score_at_rank(rank)
    scope = Trends::Status.allowed.select(Trends::Status.arel_table[Arel.star], 'ROW_NUMBER() OVER(ORDER BY score DESC) AS rank')
    Trends::Status.select('s.score').from(scope.arel.as('s')).find_by('s.rank = ?', rank)&.score
  end
end
