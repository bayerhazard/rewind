# CI-Build: baut FROM der funktionierenden Basis (enthält node-bundle + olares-cli)
# und kopiert die aktuellen App-Dateien darüber. Der lokale Build nutzt Dockerfile.new
# mit demselben Muster. Die Basis ist auf ghcr.io/bayerhazard/rewind:1.0.15 gepusht.
#
# Portabilität: KEINE Olares-Credentials ins Image. Das früher eingebackene
# olares-cli-Profil wird entfernt; Rewind loggt sich zur Laufzeit über das UI
# ein und legt das Profil auf dem persistenten /Data-Volume ab (siehe
# backup-manager.py, OLARES_HOME). HOME wird dorthin gesetzt.
FROM ghcr.io/bayerhazard/rewind:1.0.15

WORKDIR /app

# Eingebackenes olares-cli-Profil (aimighty_olares.de.enc + master.key) strippen –
# Credentials gehören nicht ins Image.
RUN rm -rf /root/.local/share/olares-cli /root/.olares-cli

# pg_dump/psql für den DB-Export (DB-gestützte Apps wie LiteLLM) bereitstellen
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      postgresql-client gzip >/dev/null 2>&1 && rm -rf /var/lib/apt/lists/*

COPY backup-manager.py .
COPY backup-manager.html .
COPY logo.png .
COPY olares-config-export.sh .
COPY olares-db-export.sh .

RUN chmod +x *.sh

# olares-cli-Profil auf dem persistenten /Data-Volume (per Chart gemountet)
ENV HOME=/Data/olares-cli-home
ENV OLARES_CLI_HOME=/Data/olares-cli-home

EXPOSE 8765

CMD ["python3", "backup-manager.py", "--port", "8765"]

LABEL org.opencontainers.image.source=https://github.com/bayerhazard/rewind
LABEL org.opencontainers.image.title=Rewind
