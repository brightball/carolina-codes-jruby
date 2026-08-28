FROM jruby:9.4-jdk21

WORKDIR /app
COPY Gemfile Gemfile.lock* ./
RUN bundle install
COPY . .

ENV PORT=8080
EXPOSE 8080
CMD ["bundle", "exec", "puma", "-p", "8080", "config.ru"]
