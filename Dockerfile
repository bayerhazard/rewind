FROM python:3.12-slim

# Copy pre-built node + olares-cli bundle
COPY node-bundle /node

# Set up PATH for node
ENV PATH="/node/bin:$PATH"

# Create olares-cli wrapper script
RUN echo '#!/bin/sh' > /usr/local/bin/olares-cli && \
    echo 'exec /node/bin/node /node/lib/node_modules/@olares/cli/bin/olares-cli.js "$@"' >> /usr/local/bin/olares-cli && \
    chmod +x /usr/local/bin/olares-cli

WORKDIR /app

COPY backup-manager.py .
COPY backup-manager.html .
COPY olares-config-export.sh .
COPY olares-db-export.sh .

RUN chmod +x *.sh

EXPOSE 8765

CMD ["python3", "backup-manager.py", "--port", "8765"]

LABEL org.opencontainers.image.source=https://github.com/bayerhazard/rewind
LABEL org.opencontainers.image.title=Rewind
