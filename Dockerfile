# CRaC+Warp (not Leyden AOTCache): Fly auto_stop_machines is Lambda-like, and
# Charles Nutter pointed at JRuby's --checkpoint/--restore (CRaC) for near-instant
# restarts. Warp needs no CAP_CHECKPOINT_RESTORE / SYS_PTRACE on Fly.
# JRuby 10.0 LTS from the official image; Azul Zulu 21 is the CRaC JDK.
FROM jruby:10.0-jdk21 AS jruby
FROM azul/zulu-openjdk:21-jdk-crac

RUN apt-get update \
 && apt-get install -y --no-install-recommends libc6-dev make \
 && rm -rf /var/lib/apt/lists/*

COPY --from=jruby /opt/jruby /opt/jruby
RUN ln -sf /opt/jruby/bin/jruby /usr/local/bin/ruby \
 && ln -sf /opt/jruby/bin/jruby /usr/local/bin/jruby

ENV PATH=/opt/jruby/bin:$PATH
ENV GEM_HOME=/usr/local/bundle
ENV BUNDLE_SILENCE_ROOT_WARNING=1
ENV BUNDLE_APP_CONFIG=$GEM_HOME
ENV PATH=$GEM_HOME/bin:$PATH
RUN mkdir -p "$GEM_HOME" && chmod 777 "$GEM_HOME"

WORKDIR /app
COPY Gemfile Gemfile.lock* ./
RUN bundle install
COPY . .
RUN chmod +x bin/start

ENV PORT=8080
ENV RACK_ENV=production
ENV JRUBY_CHECKPOINT=/app/.jruby.checkpoint
# Heap is pinned (not only MaxRAMPercentage) so the checkpoint fits Fly 512mb.
# These flags apply at checkpoint. bin/start uses Warp-only JAVA_OPTS on restore
# because UseG1GC/heap/CPU are not restore-settable.
ENV JAVA_OPTS="-Xms256m -Xmx256m -XX:MaxRAMPercentage=55.0 -XX:+UseG1GC -XX:ActiveProcessorCount=1 -XX:CRaCEngine=warp"

# Pre-boot JRuby + the app with no listen socket, DB pool, or CMS registration.
# CheckpointMain SIGKILLs after snapshot (exit 137); the directory is the success signal.
RUN mkdir -p "$JRUBY_CHECKPOINT" \
 && (bundle exec jruby --nocache --checkpoint="$JRUBY_CHECKPOINT" bin/crac_checkpoint.rb; \
     echo "CRaC checkpoint exit=$?") \
 && ls -la "$JRUBY_CHECKPOINT" \
 && test -n "$(ls -A "$JRUBY_CHECKPOINT")"

EXPOSE 8080
CMD ["/bin/sh", "/app/bin/start"]
