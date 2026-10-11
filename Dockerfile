FROM docker.io/alpine
RUN apk add --no-cache bash ca-certificates postgresql-client sqlite s3cmd
WORKDIR /app
COPY backup.sh /app/
RUN chmod +x /app/backup.sh
CMD ["/app/backup.sh"]
