# Build from the repo root:  docker build -f portal/Dockerfile .
FROM ruby:3.3-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential libyaml-dev tzdata \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY gems /gems
COPY portal/Gemfile ./
RUN bundle install
COPY portal/ .
RUN chmod +x bin/*
ENV PORT=3000
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
