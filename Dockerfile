# syntax=docker/dockerfile:1
ARG RUBY_VERSION=4.0.6
FROM ruby:${RUBY_VERSION}-slim AS base
WORKDIR /rails
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    RAILS_LOG_TO_STDOUT=1
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates libyaml-0-2 && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd --gid 1000 rails && useradd --uid 1000 --gid 1000 --create-home rails

FROM base AS dependencies
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock .ruby-version ./
RUN gem install bundler -v "$(sed -n '/BUNDLED WITH/{n;s/^[[:space:]]*//;p;}' Gemfile.lock)" --no-document

# Portable CI image; also used by Compose for local development.
FROM dependencies AS test
RUN bundle install && bundle exec bootsnap precompile --gemfile
COPY --chown=rails:rails . .
RUN mkdir -p tmp/pids log && chown -R rails:rails /rails
USER rails
ENV RAILS_ENV=test RUBOCOP_CACHE_ROOT=/rails/tmp/rubocop
CMD ["bin/rails", "test"]

# Browser tooling is limited to this target; it is not shipped in production.
FROM test AS system-test
USER root
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y chromium chromium-driver && \
    rm -rf /var/lib/apt/lists/*
USER rails
ENV CHROME_BIN=/usr/bin/chromium SE_CHROMEDRIVER=/usr/bin/chromedriver CI=true
CMD ["bin/rails", "test:system"]

FROM dependencies AS build
ENV BUNDLE_WITHOUT=development:test RAILS_ENV=production
RUN bundle install && bundle exec bootsnap precompile --gemfile
COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

FROM base AS production
ENV BUNDLE_WITHOUT=development:test \
    RAILS_ENV=production \
    PORT=3000
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=rails:rails /rails /rails
RUN mkdir -p tmp/pids log && chown -R rails:rails tmp log
USER rails
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ruby -rnet/http -e 'uri = URI("http://127.0.0.1:#{ENV.fetch("PORT", "3000")}/up"); response = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) { |http| http.get(uri.request_uri) }; exit(response.code == "200" ? 0 : 1)'
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
