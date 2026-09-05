FROM jruby:10.0-jre21

WORKDIR /app
COPY Gemfile Gemfile.lock* ./
RUN bundle install
COPY . .

ENV PORT=8080
ENV RACK_ENV=production
ENV JAVA_OPTS="-XX:MaxRAMPercentage=55.0 -XX:+UseG1GC -XX:ActiveProcessorCount=1"
EXPOSE 8080
CMD ["bundle", "exec", "puma", "config.ru"]
