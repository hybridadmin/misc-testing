FROM jenkins/jenkins:2.504.1-lts-jdk17

# ── Metadata ────────────────────────────────────────────────
LABEL maintainer="devops-team" \
      description="Production-hardened Jenkins with dark theme, Docker, Python, and Kustomize"

# ── Skip the setup wizard — JCasC handles everything ────────
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false \
  -Djava.awt.headless=true \
  -Xms512m \
  -Xmx1024m \
  -XX:+UseG1GC \
  -XX:+UseStringDeduplication \
  -Dorg.apache.commons.jelly.tags.fmt.timeZone=UTC"

# ── Install plugins (done as jenkins user for correct perms) ─
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli \
      --plugin-file /usr/share/jenkins/ref/plugins.txt \
      --verbose

# ── System packages (switch to root) ───────────────────────
USER root

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        python3 \
        python3-pip \
        python3-venv \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# ── Docker CLI only (daemon is the DinD sidecar) ───────────
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ── Kustomize (pinned version) ─────────────────────────────
ARG KUSTOMIZE_VERSION=5.6.0
RUN curl -sL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_$(dpkg --print-architecture).tar.gz" \
    | tar xz -C /usr/local/bin/

# ── SSH known hosts (GitHub) ────────────────────────────────
# Pre-seed GitHub's SSH host keys so git-over-SSH works without
# manual host key acceptance inside the container.
RUN mkdir -p /var/jenkins_home/.ssh \
    && ssh-keyscan -t ed25519,rsa,ecdsa github.com >> /var/jenkins_home/.ssh/known_hosts 2>/dev/null \
    && chmod 700 /var/jenkins_home/.ssh \
    && chmod 644 /var/jenkins_home/.ssh/known_hosts

# ── Copy JCasC config ──────────────────────────────────────
COPY casc.yaml /var/jenkins_home/casc.yaml

# ── Filesystem permissions ──────────────────────────────────
RUN chown -R jenkins:jenkins /var/jenkins_home

# ── Healthcheck ─────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -fsSL http://localhost:8080/login || exit 1

# ── Drop back to non-root ──────────────────────────────────
USER jenkins

EXPOSE 8080 50000
