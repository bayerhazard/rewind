FROM python:3.12-slim

WORKDIR /app

COPY backup-manager.py .
COPY backup-manager.html .
COPY olares-config-export.sh .
COPY olares-db-export.sh .

RUN chmod +x *.sh

EXPOSE 8765

CMD ["python3", "backup-manager.py", "--port", "8765"]
