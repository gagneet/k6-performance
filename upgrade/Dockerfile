FROM grafana/k6:latest AS k6-bin

FROM python:3.11-slim

# ── system tools needed by the audit backends ──────────────────────────────
# git       — HEAD SHA detection for audit↔k6 correlation
# bash      — code-audit.sh & run-audit.sh require bash 4+
# jq        — RepoLens requires jq for its JSON config parsing
# curl      — Claude Code installer; also used for healthchecks
# ca-certs  — TLS for agent CLI egress
# coreutils — the `timeout` binary RepoLens uses as an agent watchdog
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      bash \
      jq \
      curl \
      ca-certificates \
      coreutils \
 && rm -rf /var/lib/apt/lists/*

COPY --from=k6-bin /usr/bin/k6 /usr/bin/k6

# ── optional: install Claude Code at build time ────────────────────────────
# Set --build-arg INSTALL_CLAUDE_CODE=1 on `docker compose build` to bake it in.
# At runtime the operator still needs to provide ANTHROPIC_API_KEY (or do a
# one-time `claude` interactive login to a mounted home dir). Default is
# skipped so the portal image stays slim and the build doesn't reach out
# to claude.ai/install.sh unexpectedly.
ARG INSTALL_CLAUDE_CODE=0
RUN if [ "$INSTALL_CLAUDE_CODE" = "1" ]; then \
      curl -fsSL https://claude.ai/install.sh | bash || \
      echo "claude install failed; set INSTALL_CLAUDE_CODE=0 and install manually"; \
    fi

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
