# CRaC+Warp (not Leyden AOTCache): Fly auto_stop_machines is Lambda-like, and
# Charles Nutter pointed at JRuby's --checkpoint/--restore (CRaC) for near-instant
# restarts. Warp needs no CAP_CHECKPOINT_RESTORE / SYS_PTRACE on Fly.
# JRuby 10.0 LTS from the official image; Azul Zulu 27 is the CRaC JDK.
# No published azul/zulu-openjdk:27-jdk-crac tag at GA — overlay the CA tarball.
FROM jruby:10.0-jdk25 AS jruby
FROM ubuntu:22.04

ARG TARGETARCH=amd64
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
ENV JAVA_HOME=/usr/lib/jvm/zulu27-ca-crac
ENV PATH=$JAVA_HOME/bin:$PATH

# zulu27.28.101-ca-crac-jdk27.0.0 (Warp CRaC). TARGETARCH is amd64/arm64.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libc6-dev make locales \
 && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
 && locale-gen en_US.UTF-8 \
 && case "$TARGETARCH" in \
      amd64) zulu_arch=x64 ;; \
      arm64) zulu_arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://cdn.azul.com/zulu/bin/zulu27.28.101-ca-crac-jdk27.0.0-linux_${zulu_arch}.tar.gz" \
      -o /tmp/zulu27-crac.tar.gz \
 && mkdir -p "$JAVA_HOME" \
 && tar --extract --file /tmp/zulu27-crac.tar.gz --directory "$JAVA_HOME" --strip-components 1 \
 && rm /tmp/zulu27-crac.tar.gz \
 && ln -sf "$JAVA_HOME/bin/java" /usr/local/bin/java \
 && test -x "$JAVA_HOME/bin/warp" \
 && grep -q 'JAVA_VERSION="27"' "$JAVA_HOME/release" \
 && grep -q CRaC "$JAVA_HOME/release" \
 && rm -rf /var/lib/apt/lists/*

COPY --from=jruby /opt/jruby /opt/jruby
RUN ln -sf /opt/jruby/bin/jruby /usr/local/bin/ruby \
 && ln -sf /opt/jruby/bin/jruby /usr/local/bin/jruby

ENV PATH=/opt/jruby/bin:$PATH
ENV GEM_HOME=/usr/local/bundle
ENV BUNDLE_SILENCE_ROOT_WARNING=1
ENV BUNDLE_APP_CONFIG=$GEM_HOME
ENV BUNDLE_WITHOUT=development:test
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
# CPUFeatures=generic: Depot builders have extra AVX-512 bits Firecracker VMs
# lack. These flags apply at checkpoint. bin/start uses Warp-only JAVA_OPTS on
# restore (GC/heap/CPU flags are not restore-settable).
ENV JAVA_OPTS="-Xms256m -Xmx256m -XX:MaxRAMPercentage=55.0 -XX:+UseG1GC -XX:ActiveProcessorCount=1 -XX:CRaCEngine=warp -XX:CPUFeatures=generic"

# Pre-boot JRuby + the app with no listen socket, DB pool, or CMS registration.
# CheckpointMain SIGKILLs after snapshot (exit 137); the directory is the success signal.
RUN mkdir -p "$JRUBY_CHECKPOINT" \
 && (bundle exec jruby --nocache --checkpoint="$JRUBY_CHECKPOINT" bin/crac_checkpoint.rb; \
     echo "CRaC checkpoint exit=$?") \
 && ls -la "$JRUBY_CHECKPOINT" \
 && test -n "$(ls -A "$JRUBY_CHECKPOINT")"

EXPOSE 8080
CMD ["/bin/sh", "/app/bin/start"]
