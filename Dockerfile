FROM ruby:3.4.9-slim-trixie

RUN apt-get update -qq && \
  apt-get install -y --no-install-recommends build-essential libsqlite3-dev && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

COPY Gemfile flu-rails.gemspec ./
COPY lib/flu-rails/version.rb lib/flu-rails/
RUN bundle install

COPY . .
