# Egress proxy: the MCP container has no direct internet access; only the hosts in `allowed` pass.
FROM alpine:3.22
RUN apk add --no-cache tinyproxy
COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY allowed /etc/tinyproxy/allowed
USER nobody
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
