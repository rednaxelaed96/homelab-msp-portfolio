FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y pgbouncer postgresql-client curl python3 && rm -rf /var/lib/apt/lists/*
RUN useradd -r -s /bin/false pgbouncer
COPY pgbouncer.ini /etc/pgbouncer/pgbouncer.ini
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
RUN mkdir -p /etc/pgbouncer && chown -R pgbouncer:pgbouncer /etc/pgbouncer
USER pgbouncer
CMD ["/entrypoint.sh"]