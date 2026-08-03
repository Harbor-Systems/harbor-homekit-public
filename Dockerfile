FROM golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS gateway-build

WORKDIR /src
COPY go.mod go.sum ./
COPY cmd/whip-gateway ./cmd/whip-gateway
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" \
    -o /out/harbor-whip-gateway ./cmd/whip-gateway

FROM alexxit/go2rtc:1.9.14@sha256:675c318b23c06fd862a61d262240c9a63436b4050d177ffc68a32710d9e05bae

COPY --from=gateway-build /out/harbor-whip-gateway /usr/local/bin/
COPY scripts/run-container.sh /usr/local/bin/harbor-homekit-container
RUN chmod 0755 /usr/local/bin/harbor-whip-gateway \
    /usr/local/bin/harbor-homekit-container \
    && addgroup -g 1000 harbor \
    && adduser -D -H -u 1000 -G harbor harbor \
    && mkdir -p /harbor /config \
    && chown -R harbor:harbor /harbor /config

USER harbor
CMD ["/usr/local/bin/harbor-homekit-container"]
