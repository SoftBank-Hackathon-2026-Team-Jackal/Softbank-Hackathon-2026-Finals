FROM alpine:3.22
RUN apk add --no-cache pgbouncer postgresql16-client
COPY pgbouncer.ini userlist.txt /etc/pgbouncer/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 6432
ENTRYPOINT ["/entrypoint.sh"]
