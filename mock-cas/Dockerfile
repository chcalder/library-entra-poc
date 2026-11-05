# Build from the repo root:  docker build -f mock-cas/Dockerfile .
FROM ruby:3.3-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY mock-cas/Gemfile ./
RUN bundle install
COPY mock-cas/ .
EXPOSE 8081
CMD ["bundle", "exec", "rackup", "-o", "0.0.0.0", "-p", "8081"]
