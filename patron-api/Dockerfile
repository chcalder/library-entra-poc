# Build from the repo root:  docker build -f patron-api/Dockerfile .
FROM ruby:3.3-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential libyaml-dev tzdata \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY gems /gems
COPY patron-api/Gemfile ./
RUN bundle install
COPY patron-api/ .
RUN chmod +x bin/*
ENV PORT=3001
EXPOSE 3001
# The overdue-notices Container Apps Job uses this image with: bin/overdue_notices
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
