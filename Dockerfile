# GitBucket, packaged for Railway.
#
# The published image is fine as far as it goes; three things it cannot do on its
# own are why this layer exists:
#
#   * GitBucket's first migration inserts a `root` account with the password
#     "root" and there is no environment variable to change it, so the entrypoint
#     seeds it in the database before the public port is ever bound. That needs a
#     PostgreSQL client the image does not carry.
#   * Jetty only marks the session cookie `Secure` when the packaged web.xml says
#     so, and behind Railway's TLS-terminating edge every request reaches the
#     container as plain HTTP.
#   * The JVM sizes thread pools from the 48-core host rather than the cgroup.
FROM ghcr.io/gitbucket/gitbucket:latest

USER root

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        postgresql-client \
        zip \
        unzip; \
    rm -rf /var/lib/apt/lists/*; \
    command -v psql; \
    command -v curl; \
    command -v sha1sum; \
    command -v bash

# Add <secure>true</secure> to the servlet cookie-config. The element order the
# schema wants is http-only then secure, so anchor the edit on the existing line.
RUN set -eux; \
    cd /tmp; \
    unzip -o -q /opt/gitbucket.war WEB-INF/web.xml; \
    grep -q '<http-only>true</http-only>' WEB-INF/web.xml; \
    sed -i 's|<http-only>true</http-only>|<http-only>true</http-only>\n      <secure>true</secure>|' WEB-INF/web.xml; \
    grep -q '<secure>true</secure>' WEB-INF/web.xml; \
    zip -q /opt/gitbucket.war WEB-INF/web.xml; \
    unzip -p /opt/gitbucket.war WEB-INF/web.xml | grep -q '<secure>true</secure>'; \
    rm -rf /tmp/WEB-INF

COPY entrypoint.sh /usr/local/bin/gitbucket-entrypoint.sh
RUN set -eux; \
    chmod 0755 /usr/local/bin/gitbucket-entrypoint.sh; \
    bash -n /usr/local/bin/gitbucket-entrypoint.sh

ENV GITBUCKET_HOME=/gitbucket

# 8080 serves the web UI, the GitHub-compatible API and git-over-HTTP.
# 29418 is the SSH daemon, published through a Railway TCP proxy.
EXPOSE 8080 29418

# The base image keeps its own ENTRYPOINT (the Temurin CA-certificate shim), which
# execs whatever CMD names — declaring an ENTRYPOINT here would empty that CMD.
CMD ["/usr/local/bin/gitbucket-entrypoint.sh"]
